resource "aws_eks_cluster" "cluster" {
  name     = var.cluster_name
  version  = var.eks_version
  role_arn = var.cluster_role_arn
  vpc_config {
    subnet_ids         = concat(var.public_subnets, var.private_subnets)
    security_group_ids = [var.cluster_sg_id]
  }
}

resource "aws_eks_node_group" "workers" {
  count           = 3 # build \3 node groups. first one (index 0) is on_demand, second and third ones are spot. 1 spot node group per az
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = count.index == 0 ? "on_demand" : "worker_${count.index}"
  node_role_arn   = var.nodegroup_role_arn
  subnet_ids      = count.index == 0 ? var.private_subnets : [var.private_subnets[count.index - 1]]
  instance_types  = count.index == 0 ? var.on_demand_type : var.worker_type
  capacity_type   = count.index == 0 ? "ON_DEMAND" : "SPOT"
  labels          = count.index == 0 ? { instance_type = "on_demand" } : { instance_type = "spot", az = "az-${count.index}" }
  tags = count.index == 0 ? {
    Name = "${var.cluster_name}_eks_nodes"
    } : {
    Name                                                      = "${var.cluster_name}_eks_nodes"
    "k8s.io/cluster-autoscaler/node-template/label/intent"    = "app"
    "k8s.io/cluster-autoscaler/node-template/label/lifecycle" = "Ec2Spot"
    "k8s.io/cluster-autoscaler/node-template/label/type"      = "worker"
  }
  scaling_config {
    desired_size = count.index == 0 ? var.on_demand_size.desired_size : var.worker_size.desired_size
    max_size     = count.index == 0 ? var.on_demand_size.max_size : var.worker_size.max_size
    min_size     = count.index == 0 ? var.on_demand_size.min_size : var.worker_size.min_size
  }
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

data "tls_certificate" "cluster_certificate" {
  url = aws_eks_cluster.cluster.identity.0.oidc.0.issuer
}

resource "aws_iam_openid_connect_provider" "cluster_oidc_provider" {
  url             = aws_eks_cluster.cluster.identity.0.oidc.0.issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster_certificate.certificates.0.sha1_fingerprint]
}
