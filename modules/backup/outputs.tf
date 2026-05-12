output "backup_vault_arn" {
  value = aws_backup_vault.langfuse.arn
}

output "backup_vault_name" {
  value = aws_backup_vault.langfuse.name
}

output "backup_plan_id" {
  value = aws_backup_plan.efs.id
}
