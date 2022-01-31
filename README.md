# EKS with Terraform

This module builds an EKS cluster using terraform and installs a number of helpful utilities on it. 

The following AWS resources will be created with terraform apply:

- VPC
- Internet gateway
- Public and private route tables
- Public and private subnets
- Elastic IP
- Nat gateway
- Security group
- IAM roles and policies
- EKS cluster with managed node group (this will create the relevant autoscaling groups)
- IAM OIDC provider
- Route53 records

Once the cluster is ready, the following workloads will be deployed to it:

- Prometheus and Grafana for monitoring metrics
- EFK stack (Elastic, Fluentd and Kibana) for logs
- Cert manager and two letsencrypt ClusterIssuer objects for generating certificates
- Traefik ingress controller
- Node termination handler for handling spot instance and other interruptions
- Cluster autoscaler for worker nodes

## Prerequisites

- An AWS user with permission to create the required resouces (including IAM roles, policies and attaching policy)
- Provide an email address in the `./modules/eks_setup/cert.yaml` file
- AWS CLI
- Kubectl
- Terraform
- A Route53 hosting_zone

## Usage

- Configure your AWS CLI region
- export `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (required by terraform)
- Check the var.tf file and make sure that you are happy with the default options
- Execute the following

```hcl
Terraform init
Terraform plan
Terraform apply
```

Terraform will first create the required resources in AWS, then it will proceed with deploying the utilities on the cluster. 
Once apply has finished, you should be able to access Kibana, Grafana and Traefik dashboard. The default url respectively are:

- https://logs.dev.<your hosting_zone>
- https://monitoring.dev.<your hosting_zone>
- https://ingress.dev.<your hosting_zone>

By default Cert manager will issue certificates for the routes from the prod letsencrypt issuer. Keep in mind the rate limits!

Please note that EKF stack DOES NOT come with basic security enabled. Kibana is simply behind a Traefik basic auth middleware.
Traefik dashboard is also behind a different basic auth middleware. This is to provide a very basic level of security and should not be used in production as it is.

Grafana comes with kube-prometheus-stack and is using the default credentials from the helm chart. Please refer to [here](ps://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/values.yaml) for complete values.yaml for kube-prometheus-stack release.
