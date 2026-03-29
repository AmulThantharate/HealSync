terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes"; version = "~> 2.27"; configuration_aliases = [kubernetes] }
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata { name = "monitoring"; labels = { "app.kubernetes.io/managed-by" = "terraform" } }
}

resource "kubernetes_config_map" "prometheus_config" {
  metadata { name = "prometheus-config"; namespace = kubernetes_namespace.monitoring.metadata[0].name }
  data = {
    "prometheus.yml" = <<-YAML
      global:
        scrape_interval: 15s
        external_labels:
          cluster: "${var.eks_cluster_name}"
          environment: "${var.environment}"
      rule_files:
        - /etc/prometheus/alerts.yml
      scrape_configs:
        - job_name: kubernetes-apiservers
          kubernetes_sd_configs: [{role: endpoints}]
          scheme: https
          tls_config: {ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt}
          bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
          relabel_configs:
            - source_labels: [__meta_kubernetes_namespace,__meta_kubernetes_service_name,__meta_kubernetes_endpoint_port_name]
              action: keep; regex: default;kubernetes;https
        - job_name: kubernetes-pods
          kubernetes_sd_configs: [{role: pod}]
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep; regex: "true"
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace; target_label: __metrics_path__; regex: (.+)
            - source_labels: [__address__,__meta_kubernetes_pod_annotation_prometheus_io_port]
              action: replace; regex: ([^:]+)(?::\d+)?;(\d+); replacement: $1:$2; target_label: __address__
            - action: labelmap; regex: __meta_kubernetes_pod_label_(.+)
        - job_name: kube-state-metrics
          static_configs: [{targets: ["kube-state-metrics.monitoring:8080"]}]
        - job_name: node-exporter
          kubernetes_sd_configs: [{role: node}]
          relabel_configs:
            - source_labels: [__address__]
              action: replace; regex: ([^:]+)(:\d+)?; replacement: $1:9100; target_label: __address__
        - job_name: flask-app
          kubernetes_sd_configs: [{role: pod, namespaces: {names: [healsync]}}]
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep; regex: "true"
    YAML
    "alerts.yml" = <<-YAML
      groups:
        - name: healsync-alerts
          rules:
            - alert: PrimaryDBDown
              expr: up{job="kubernetes-apiservers"} == 0
              for: 2m
              labels: {severity: critical}
              annotations: {summary: "EKS API unreachable — HealSync failover may be needed"}
            - alert: PodCrashLooping
              expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
              for: 5m
              labels: {severity: warning}
              annotations: {summary: "Pod {{ $labels.pod }} is crash-looping"}
            - alert: NodeMemoryPressure
              expr: (node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes) < 0.1
              for: 5m
              labels: {severity: warning}
              annotations: {summary: "Node memory < 10%"}
            - alert: FlaskAppDown
              expr: up{job="flask-app"} == 0
              for: 1m
              labels: {severity: critical}
              annotations: {summary: "Flask HealSync app is unreachable"}
    YAML
  }
}

resource "kubernetes_service_account" "prometheus" {
  metadata { name = "prometheus"; namespace = kubernetes_namespace.monitoring.metadata[0].name }
}
resource "kubernetes_cluster_role" "prometheus" {
  metadata { name = "prometheus" }
  rule { api_groups = [""]; resources = ["nodes","nodes/proxy","services","endpoints","pods"]; verbs = ["get","list","watch"] }
  rule { api_groups = ["extensions"]; resources = ["ingresses"]; verbs = ["get","list","watch"] }
  rule { non_resource_urls = ["/metrics"]; verbs = ["get"] }
}
resource "kubernetes_cluster_role_binding" "prometheus" {
  metadata { name = "prometheus" }
  role_ref { api_group = "rbac.authorization.k8s.io"; kind = "ClusterRole"; name = "prometheus" }
  subject  { kind = "ServiceAccount"; name = "prometheus"; namespace = kubernetes_namespace.monitoring.metadata[0].name }
}

resource "kubernetes_deployment" "prometheus" {
  metadata { name = "prometheus"; namespace = kubernetes_namespace.monitoring.metadata[0].name; labels = { app = "prometheus" } }
  spec {
    replicas = 1
    selector { match_labels = { app = "prometheus" } }
    template {
      metadata { labels = { app = "prometheus" } }
      spec {
        service_account_name = kubernetes_service_account.prometheus.metadata[0].name
        container {
          name  = "prometheus"
          image = "prom/prometheus:v2.50.1"
          args  = ["--config.file=/etc/prometheus/prometheus.yml","--storage.tsdb.path=/prometheus","--storage.tsdb.retention.time=15d","--web.enable-lifecycle"]
          port  { container_port = 9090 }
          volume_mount { name = "config"; mount_path = "/etc/prometheus" }
          volume_mount { name = "data";   mount_path = "/prometheus" }
          resources {
            requests = { cpu = "200m"; memory = "512Mi" }
            limits   = { cpu = "500m"; memory = "2Gi" }
          }
        }
        volume { name = "config"; config_map { name = kubernetes_config_map.prometheus_config.metadata[0].name } }
        volume { name = "data";   empty_dir {} }
      }
    }
  }
}
resource "kubernetes_service" "prometheus" {
  metadata { name = "prometheus"; namespace = kubernetes_namespace.monitoring.metadata[0].name }
  spec { selector = { app = "prometheus" }; port { port = 9090; target_port = 9090 } }
}

resource "kubernetes_secret" "grafana" {
  metadata { name = "grafana-credentials"; namespace = kubernetes_namespace.monitoring.metadata[0].name }
  data = { "admin-user" = "admin"; "admin-password" = var.grafana_password }
}

resource "kubernetes_config_map" "grafana_datasources" {
  metadata { name = "grafana-datasources"; namespace = kubernetes_namespace.monitoring.metadata[0].name }
  data = {
    "datasources.yaml" = <<-YAML
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          url: http://prometheus:9090
          isDefault: true
          jsonData:
            timeInterval: "15s"
        - name: CloudWatch
          type: cloudwatch
          jsonData:
            authType: default
            defaultRegion: "${var.aws_region}"
    YAML
  }
}

resource "kubernetes_config_map" "grafana_dashboards_provider" {
  metadata { name = "grafana-dashboards-provider"; namespace = kubernetes_namespace.monitoring.metadata[0].name }
  data = {
    "dashboards.yaml" = <<-YAML
      apiVersion: 1
      providers:
        - name: healsync-dashboards
          type: file
          updateIntervalSeconds: 30
          options:
            path: /var/lib/grafana/dashboards
    YAML
  }
}

resource "kubernetes_deployment" "grafana" {
  metadata { name = "grafana"; namespace = kubernetes_namespace.monitoring.metadata[0].name; labels = { app = "grafana" } }
  spec {
    replicas = 1
    selector { match_labels = { app = "grafana" } }
    template {
      metadata { labels = { app = "grafana" } }
      spec {
        container {
          name  = "grafana"
          image = "grafana/grafana:10.3.3"
          env { name = "GF_SECURITY_ADMIN_USER";     value_from { secret_key_ref { name = "grafana-credentials"; key = "admin-user" } } }
          env { name = "GF_SECURITY_ADMIN_PASSWORD"; value_from { secret_key_ref { name = "grafana-credentials"; key = "admin-password" } } }
          env { name = "GF_PATHS_PROVISIONING";      value = "/etc/grafana/provisioning" }
          port { container_port = 3000 }
          volume_mount { name = "datasources";         mount_path = "/etc/grafana/provisioning/datasources" }
          volume_mount { name = "dashboards-provider"; mount_path = "/etc/grafana/provisioning/dashboards" }
          resources {
            requests = { cpu = "100m"; memory = "256Mi" }
            limits   = { cpu = "300m"; memory = "512Mi" }
          }
          liveness_probe { http_get { path = "/api/health"; port = 3000 }; initial_delay_seconds = 30; period_seconds = 10 }
        }
        volume { name = "datasources";         config_map { name = kubernetes_config_map.grafana_datasources.metadata[0].name } }
        volume { name = "dashboards-provider"; config_map { name = kubernetes_config_map.grafana_dashboards_provider.metadata[0].name } }
      }
    }
  }
}
resource "kubernetes_service" "grafana" {
  metadata { name = "grafana"; namespace = kubernetes_namespace.monitoring.metadata[0].name }
  spec { selector = { app = "grafana" }; type = "ClusterIP"; port { port = 3000; target_port = 3000 } }
}

resource "kubernetes_daemonset" "node_exporter" {
  metadata { name = "node-exporter"; namespace = kubernetes_namespace.monitoring.metadata[0].name; labels = { app = "node-exporter" } }
  spec {
    selector { match_labels = { app = "node-exporter" } }
    template {
      metadata { labels = { app = "node-exporter" } }
      spec {
        host_network = true; host_pid = true
        toleration { operator = "Exists" }
        container {
          name  = "node-exporter"
          image = "prom/node-exporter:v1.7.0"
          args  = ["--path.rootfs=/host","--path.procfs=/host/proc","--path.sysfs=/host/sys"]
          port  { container_port = 9100 }
          volume_mount { name = "proc"; mount_path = "/host/proc"; read_only = true }
          volume_mount { name = "sys";  mount_path = "/host/sys";  read_only = true }
          volume_mount { name = "root"; mount_path = "/host";      read_only = true }
          resources { requests = { cpu = "50m"; memory = "64Mi" }; limits = { cpu = "200m"; memory = "200Mi" } }
        }
        volume { name = "proc"; host_path { path = "/proc" } }
        volume { name = "sys";  host_path { path = "/sys" } }
        volume { name = "root"; host_path { path = "/" } }
      }
    }
  }
}
resource "kubernetes_service" "node_exporter" {
  metadata { name = "node-exporter"; namespace = kubernetes_namespace.monitoring.metadata[0].name }
  spec { selector = { app = "node-exporter" }; port { port = 9100; target_port = 9100 } }
}

resource "kubernetes_deployment" "kube_state_metrics" {
  metadata { name = "kube-state-metrics"; namespace = kubernetes_namespace.monitoring.metadata[0].name; labels = { app = "kube-state-metrics" } }
  spec {
    replicas = 1
    selector { match_labels = { app = "kube-state-metrics" } }
    template {
      metadata { labels = { app = "kube-state-metrics" } }
      spec {
        service_account_name = kubernetes_service_account.prometheus.metadata[0].name
        container {
          name  = "kube-state-metrics"
          image = "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.11.0"
          port  { container_port = 8080 }
          resources { requests = { cpu = "50m"; memory = "64Mi" }; limits = { cpu = "200m"; memory = "256Mi" } }
        }
      }
    }
  }
}
resource "kubernetes_service" "kube_state_metrics" {
  metadata { name = "kube-state-metrics"; namespace = kubernetes_namespace.monitoring.metadata[0].name }
  spec { selector = { app = "kube-state-metrics" }; port { port = 8080; target_port = 8080 } }
}
