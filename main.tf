locals {
  cluster_name = lower(var.env)
}

provider "aws" {
  region              = var.region
  allowed_account_ids = var.account_id
  default_tags {
    tags = {
      Name = local.cluster_name
      ENV  = local.cluster_name
    }
  }
}

module "network" {
  source       = "./modules/network"
  cluster_name = local.cluster_name
  cidr         = var.cidr
  az           = var.az
}

module "iam" {
  source       = "./modules/iam"
  cluster_name = local.cluster_name
}

module "eks" {
  source             = "./modules/eks"
  depends_on         = [module.iam, module.network]
  cluster_name       = local.cluster_name
  eks_version        = var.eks_version
  public_subnets     = module.network.public_subnet_id
  private_subnets    = module.network.private_subnet_id
  cluster_sg_id      = module.network.cluster_sg_id
  cluster_role_arn   = module.iam.cluster_role_arn
  nodegroup_role_arn = module.iam.nodegroup_role_arn
  on_demand_size     = var.on_demand_size
  on_demand_type     = var.on_demand_type
  worker_size        = var.worker_size
  worker_type        = var.worker_type
}

data "aws_eks_cluster" "eks" {
  depends_on = [module.eks]
  name       = module.eks.cluster_name
}

data "aws_eks_cluster_auth" "eks" {
  depends_on = [module.eks]
  name       = module.eks.cluster_id
}

data "aws_eks_node_groups" "node_groups" {
  depends_on   = [module.eks]
  cluster_name = module.eks.cluster_name
}

locals {
  node_group_names = join(",", data.aws_eks_node_groups.node_groups.names)
}

data "aws_eks_node_group" "node_group" {
  count = length(data.aws_eks_node_groups.node_groups)

  cluster_name    = local.cluster_name
  node_group_name = split(",", local.node_group_names)[count.index]
}

data "aws_autoscaling_group" "asg" {
  count = length(data.aws_eks_node_groups.node_groups)
  name  = data.aws_eks_node_group.node_group[count.index].resources[0].autoscaling_groups[0].name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.eks.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.eks.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority.0.data)
    token                  = data.aws_eks_cluster_auth.eks.token
  }
}

module "eks_setup" {
  source                 = "./modules/eks_setup"
  depends_on             = [module.eks]
  host_name              = var.host_name
  cluster_name           = module.eks.cluster_name
  region                 = var.region
  asg                    = data.aws_autoscaling_group.asg
  nodegroup_role_name    = module.iam.nodegroup_role_name
  encrypted_kibana_pass  = var.encrypted_kibana_pass
  encrypted_traefik_pass = var.encrypted_traefik_pass
}
