output "task_execution_role_arn" {
  value = aws_iam_role.task_execution.arn
}

output "web_task_role_arn" {
  value = aws_iam_role.web_task.arn
}

output "worker_task_role_arn" {
  value = aws_iam_role.worker_task.arn
}

output "clickhouse_task_role_arn" {
  value = aws_iam_role.clickhouse_task.arn
}
