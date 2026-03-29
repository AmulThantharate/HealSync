# HealSync Test Commands (Local + Kubernetes)

## Local (Docker Compose)

### 1. Clean start
```bash
docker compose down -v
docker compose up -d --build
docker compose ps
```

### 2. Configure MySQL replication (primary -> secondary)
```bash
docker exec healsync-mysql-primary mysql -uroot -proot123 -e "
CREATE USER IF NOT EXISTS 'replicator'@'%' IDENTIFIED WITH mysql_native_password BY 'RepPass123!';
GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'%';
FLUSH PRIVILEGES;"
```

```bash
docker exec healsync-mysql-secondary mysql -uroot -proot123 -e "
STOP REPLICA;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-primary',
  SOURCE_PORT=3306,
  SOURCE_USER='replicator',
  SOURCE_PASSWORD='RepPass123!',
  SOURCE_AUTO_POSITION=1;
START REPLICA;"
```

### 3. Verify app and replication
```bash
curl -s http://localhost:5000/api/status | jq .
curl -s http://localhost:5000/api/replication | jq .
```

### 4. Write todo and verify replication flag
```bash
curl -s -X POST http://localhost:5000/api/todos \
  -H "Content-Type: application/json" \
  -d '{"task":"todo-local-1"}' | jq .
```

### 5. Confirm same row on secondary
```bash
docker exec healsync-mysql-secondary mysql -uroot -proot123 -e "
SELECT id,task,written_to,created_at FROM healsync.todos ORDER BY id DESC LIMIT 5;"
```

### 6. Simulate primary failure and verify failover
```bash
docker stop healsync-mysql-primary
sleep 35
curl -s http://localhost:5000/api/status | jq .
```

### 7. Write after failover
```bash
curl -s -X POST http://localhost:5000/api/todos \
  -H "Content-Type: application/json" \
  -d '{"task":"todo-after-failover"}' | jq .
```

---

## Kubernetes (2-node VM cluster)

### 1. Build and push app image
```bash
docker build -t <registry>/healsync-flask-app:latest ./app
docker push <registry>/healsync-flask-app:latest
```

### 2. Update image in deployment
```bash
# edit k8s/flask/deployment.yaml
# set image: <registry>/healsync-flask-app:latest
```

### 3. Apply manifests
```bash
kubectl apply -f k8s/healsync-namespace.yaml
kubectl apply -f k8s/mysql/secret.yaml
kubectl apply -f k8s/mysql/primary.yaml
kubectl apply -f k8s/mysql/secondary.yaml
kubectl apply -f k8s/flask/configmap.yaml
kubectl apply -f k8s/flask/deployment.yaml
kubectl apply -f k8s/flask/service.yaml
kubectl apply -f k8s/flask/hpa.yaml
kubectl apply -f k8s/flask/pdb.yaml
```

### 4. Wait for readiness
```bash
kubectl -n healsync rollout status deploy/mysql-primary --timeout=300s
kubectl -n healsync rollout status deploy/mysql-secondary --timeout=300s
kubectl -n healsync rollout status deploy/flask-app --timeout=300s
kubectl -n healsync get pods -o wide
```

### 5. Configure replication in cluster
```bash
kubectl -n healsync exec deploy/mysql-primary -- mysql -uroot -proot123 -e "
CREATE USER IF NOT EXISTS 'replicator'@'%' IDENTIFIED WITH mysql_native_password BY 'RepPass123!';
GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'%';
FLUSH PRIVILEGES;"
```

```bash
kubectl -n healsync exec deploy/mysql-secondary -- mysql -uroot -proot123 -e "
STOP REPLICA;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-primary',
  SOURCE_PORT=3306,
  SOURCE_USER='replicator',
  SOURCE_PASSWORD='RepPass123!',
  SOURCE_AUTO_POSITION=1;
START REPLICA;"
```

### 6. Access app
```bash
kubectl -n healsync get svc flask-app
# open: http://<node-ip>:30080
```

### 7. Failover test
```bash
kubectl -n healsync scale deploy/mysql-primary --replicas=0
# wait ~30-40s
curl -s http://<node-ip>:30080/api/status | jq .
curl -s -X POST http://<node-ip>:30080/api/todos \
  -H "Content-Type: application/json" \
  -d '{"task":"k8s-after-failover"}' | jq .
```

### 8. Recovery test
```bash
kubectl -n healsync scale deploy/mysql-primary --replicas=1
kubectl -n healsync rollout status deploy/mysql-primary --timeout=300s
```

