################
# general vars
################

variable "env" {
  type    = string
  default = "dev"
}

variable "account_id" {
  type = list(any)
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "host_name" {
  type = string
}
################
# networking vars
################

variable "cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "az" {
  type        = number
  default     = 2
  description = "How many availability zones our infra will have. If you chage this, also make sure to change local.subnet_cidr and aws_subnet.private_subnet in the network module. We need 1 subnet cidr for each az"
}
################
# kubernetes vars
################

variable "eks_version" {
  type    = string
  default = "1.21"
}

variable "on_demand_size" {
  type = object({
    desired_size = number
    max_size     = number
    min_size     = number
  })
  default = {
    desired_size = 0
    max_size     = 1
    min_size     = 0
  }
}

variable "on_demand_type" {
  type    = set(string)
  default = ["t3.medium"]
}

variable "worker_size" {
  type = object({
    desired_size = number
    max_size     = number
    min_size     = number
  })
  default = {
    desired_size = 1
    max_size     = 6
    min_size     = 1
  }
}

variable "worker_type" {
  type = set(string)
  default = [
    "t3a.large",
    "t3.large",
    "m5a.large",
    "m5.large",
    "m6i.large",
    "t3a.xlarge",
    "t3.xlarge",
    "m5a.xlarge",
    "m5.xlarge",
    "m6i.xlarge"
  ]
  description = "Pool of workers that have 1:4 cpu to memory ratio. They each have 2 or 4 cpu."
}

variable "encrypted_kibana_pass" {
  type        = string
  description = "base64 encrypted user and pass. format is name:encoded-password. For more info see https://doc.traefik.io/traefik/middlewares/http/basicauth/ and https://traefik.io/blog/traefik-proxy-kubernetes-101/ and https://hostingcanada.org/htpasswd-generator/"
}
variable "encrypted_traefik_pass" {
  type        = string
  description = "base64 encrypted user and pass. format is name:encoded-password. For more info see https://doc.traefik.io/traefik/middlewares/http/basicauth/ and https://traefik.io/blog/traefik-proxy-kubernetes-101/ and https://hostingcanada.org/htpasswd-generator/"
}
