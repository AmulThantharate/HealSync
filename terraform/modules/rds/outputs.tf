output "primary_endpoint" { value = aws_db_instance.primary.endpoint }
output "replica_endpoint" { value = aws_db_instance.replica.endpoint }
output "identifier" { value = aws_db_instance.primary.identifier }
output "rds_sg_id" { value = aws_security_group.rds.id }
