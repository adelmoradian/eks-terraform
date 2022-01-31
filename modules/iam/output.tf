output "cluster_role_arn" {
  value = aws_iam_role.cluster_role.arn
}

output "nodegroup_role_arn" {
  value = aws_iam_role.node_group_role.arn
}

output "nodegroup_role_name" {
  value = aws_iam_role.node_group_role.name
}
