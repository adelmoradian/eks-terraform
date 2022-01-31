data "aws_route53_zone" "hosting_zone" {
  name = var.host_name
}

# Namespaces and secrets
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "kubernetes_namespace" "traefik" {
  metadata {
    name = "traefik"
  }
}

resource "kubernetes_namespace" "logs" {
  metadata {
    name = "logs"
  }
}

resource "kubernetes_secret" "basic_auth_logs" {
  metadata {
    name      = "basic-auth-logs"
    namespace = kubernetes_namespace.logs.metadata[0].name
  }
  binary_data = {
    "users" = var.encrypted_kibana_pass
  }
}

resource "kubernetes_secret" "basic_auth_traefik" {
  metadata {
    name      = "basic-auth-traefik"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }
  binary_data = {
    "users" = var.encrypted_traefik_pass
  }
}

# Node termination handler
resource "helm_release" "aws-node-termination-handler" {
  namespace  = "kube-system"
  name       = "aws-node-termination-handler"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-node-termination-handler"
  version    = "0.16.0"
  values     = [file("./modules/eks_setup/aws-node-termination-handler.yaml")]
}

# cert manager
resource "helm_release" "cert-manager" {
  namespace  = "kube-system"
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "1.6.1"
  values     = [file("./modules/eks_setup/cert-manager.yaml")]
}

resource "null_resource" "local-exec" {
  depends_on = [helm_release.cert-manager]
  provisioner "local-exec" {
    environment = {
      ENV = var.cluster_name
    }
    command = "aws eks update-kubeconfig --name $ENV && sleep 10 && kubectl apply -f ./modules/eks_setup/cert.yaml"
  }
}

# Auto scaller
resource "aws_iam_policy" "autoscaler_policy" {
  name        = "${var.cluster_name}-autoscaler-policy"
  path        = "/"
  description = "Cluster Autoscaler Policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeTags",
          "ec2:DescribeLaunchTemplateVersions"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "autoscaling:UpdateAutoScalingGroup"
        ]
        Effect   = "Allow"
        Resource = [for k, v in var.asg : v.arn]
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"         = "true",
            "autoscaling:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "node_group_autoscaler_policy" {
  policy_arn = aws_iam_policy.autoscaler_policy.arn
  role       = var.nodegroup_role_name
}

resource "helm_release" "cluster-autoscaler" {
  namespace  = "kube-system"
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.11.0"
  values     = [templatefile("./modules/eks_setup/auto-scaler.yaml.tpl", { region = var.region, cluster = var.cluster_name })]
}

# Storage class
resource "kubernetes_storage_class" "sc_cheap" {
  metadata {
    name = "slow"
  }
  storage_provisioner    = "kubernetes.io/aws-ebs"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  parameters = {
    type = "st1"
    fsType : "ext4"
  }
}

resource "kubernetes_storage_class" "sc_general" {
  metadata {
    name = "general"
  }
  storage_provisioner    = "kubernetes.io/aws-ebs"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  parameters = {
    type = "gp2"
    fsType : "ext4"
  }
}

resource "kubernetes_storage_class" "sc_fast" {
  metadata {
    name = "fast"
  }
  storage_provisioner    = "kubernetes.io/aws-ebs"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  parameters = {
    type      = "io1"
    iopsPerGB = "10"
    fsType : "ext4"
  }
}

# Ingress controller
resource "kubernetes_ingress_class" "traefik" {
  metadata {
    name = "traefik-ingress-class"
  }
  spec {
    controller = "traefik.io/ingress-controller"
  }
}

resource "helm_release" "traefik" {
  depends_on       = [kubernetes_ingress_class.traefik]
  name             = "traefik"
  namespace        = kubernetes_namespace.traefik.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 300
  repository       = "https://helm.traefik.io/traefik"
  chart            = "traefik"
  version          = "10.9.1"
  values           = [file("./modules/eks_setup/traefik.yaml")]
}

resource "null_resource" "local-exec-auth" {
  depends_on = [helm_release.traefik,
    kubernetes_namespace.monitoring,
    kubernetes_namespace.logs,
    kubernetes_namespace.traefik,
    kubernetes_secret.basic_auth_logs,
  kubernetes_secret.basic_auth_traefik]
  provisioner "local-exec" {
    environment = {
      ENV = var.cluster_name
    }
    command = "aws eks update-kubeconfig --name $ENV && sleep 10 && kubectl apply -f ./modules/eks_setup/auth-middleware.yaml"
  }
}

resource "kubernetes_service" "traefik" {
  metadata {
    labels = {
      "app" = "traefik"
    }
    name      = "traefik-service"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }
  spec {
    port {
      port = 9000
    }
    selector = {
      "app.kubernetes.io/name" = "traefik"
    }
  }
}

data "kubernetes_service" "traefik" {
  depends_on = [helm_release.traefik]
  metadata {
    name      = "traefik"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }
}

resource "aws_route53_record" "traefik" {
  zone_id         = data.aws_route53_zone.hosting_zone.zone_id
  name            = "ingress.${var.cluster_name}"
  type            = "CNAME"
  ttl             = "300"
  records         = [data.kubernetes_service.traefik.status.0.load_balancer.0.ingress.0.hostname]
  allow_overwrite = false
}

resource "kubernetes_ingress" "traefik" {
  depends_on = [null_resource.local-exec, null_resource.local-exec-auth]
  metadata {
    namespace = kubernetes_namespace.traefik.metadata[0].name
    name      = "traefik"
    labels = {
      "app" = "traefik"
    }
    annotations = {
      "cert-manager.io/cluster-issuer"                   = "letsencrypt-prod"
      "traefik.ingress.kubernetes.io/router.entrypoints" = "web,websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
      "traefik.ingress.kubernetes.io/router.middlewares" = "traefik-basic-auth-traefik@kubernetescrd"
    }
  }
  spec {
    ingress_class_name = kubernetes_ingress_class.traefik.metadata[0].name
    tls {
      hosts       = [aws_route53_record.traefik.fqdn]
      secret_name = "ingress-auth-tls"
    }
    rule {
      host = aws_route53_record.traefik.fqdn
      http {
        path {
          backend {
            service_name = kubernetes_service.traefik.metadata[0].name
            service_port = 9000
          }
          path = "/"
        }
      }
    }
  }
}

# Monitoring stack
# values.yaml from here https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/values.yaml
resource "helm_release" "monitoring" {
  name             = "monitoring"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 300
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "30.0.1"
  #values           = ["./modules/eks_setup/monitoring2.yaml"]
  set {
    name  = "prometheus.prometheusSpec.nodeSelector.${"az"}"
    value = "az-1"
  }
  set {
    name  = "alertmanager.alertmanagerSpec.nodeSelector.${"az"}"
    value = "az-1"
  }
  set {
    name  = "prometheusOperator.admissionWebhooks.patch.nodeSelector.${"az"}"
    value = "az-1"
  }
  set {
    name  = "prometheusOperator.nodeSelector.${"az"}"
    value = "az-1"
  }
}

resource "aws_route53_record" "monitoring" {
  zone_id         = data.aws_route53_zone.hosting_zone.zone_id
  name            = "monitoring.${var.cluster_name}"
  type            = "CNAME"
  ttl             = "300"
  records         = [data.kubernetes_service.traefik.status.0.load_balancer.0.ingress.0.hostname]
  allow_overwrite = false
}

resource "kubernetes_ingress" "monitoring" {
  depends_on = [null_resource.local-exec, null_resource.local-exec-auth]
  metadata {
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    name      = "monitoring"
    labels = {
      "app" = "monitoring"
    }
    annotations = {
      "cert-manager.io/cluster-issuer"                   = "letsencrypt-prod"
      "traefik.ingress.kubernetes.io/router.entrypoints" = "web,websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
    }
  }
  spec {
    ingress_class_name = kubernetes_ingress_class.traefik.metadata[0].name
    tls {
      hosts       = [aws_route53_record.monitoring.fqdn]
      secret_name = "monitoring-auth-tls"
    }
    rule {
      host = aws_route53_record.monitoring.fqdn
      http {
        path {
          backend {
            service_name = "monitoring-grafana"
            service_port = 80
          }
          path = "/"
        }
      }
    }
  }
}

# Logs
resource "kubernetes_service" "elasticsearch" {
  metadata {
    namespace = kubernetes_namespace.logs.metadata[0].name
    name      = "elasticsearch"
    labels = {
      "app" = "elasticsearch"
    }
  }
  spec {
    cluster_ip = "None"
    selector = {
      "app" = "elasticsearch"
    }
    port {
      port = 9200
      name = "rest"
    }
    port {
      port = 9300
      name = "inter-node"
    }
  }
}

resource "kubernetes_stateful_set" "elasticsearch" {
  metadata {
    namespace = kubernetes_namespace.logs.metadata[0].name
    name      = "elasticsearch"
  }
  spec {
    service_name = kubernetes_service.elasticsearch.metadata[0].name
    replicas     = 3
    selector {
      match_labels = {
        "app" = "elasticsearch"
      }
    }
    volume_claim_template {
      metadata {
        name = "data"
        labels = {
          "app" = "elasticsearch"
        }
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "general"
        resources {
          requests = {
            storage = "100Gi"
          }
        }
      }
    }
    template {
      metadata {
        labels = {
          "app" = "elasticsearch"
        }
      }
      spec {
        node_selector = {
          "az" = "az-2"
        }
        container {
          name  = "elasticsearch"
          image = "docker.elastic.co/elasticsearch/elasticsearch:7.16.3"
          resources {
            limits = {
              cpu = "1000m"
            }
            requests = {
              cpu = "100m"
            }
          }
          port {
            container_port = 9200
            name           = "rest"
            protocol       = "TCP"
          }
          port {
            container_port = 9300
            name           = "inner-node"
            protocol       = "TCP"
          }
          volume_mount {
            name       = "data"
            mount_path = "/usr/share/elasticsearch/data"
          }
          env {
            name  = "cluster.name"
            value = "k8s-logs"
          }
          env {
            name = "node.name"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }
          env {
            name  = "discovery.seed_hosts"
            value = "elasticsearch-0.elasticsearch,elasticsearch-1.elasticsearch,elasticsearch-2.elasticsearch"
          }
          env {
            name  = "cluster.initial_master_nodes"
            value = "elasticsearch-0,elasticsearch-1,elasticsearch-2"
          }
          env {
            name  = "ES_JAVA_OPTS"
            value = "-Xms512m -Xmx512m"
          }
        }
        init_container {
          name    = "fix-permissions"
          image   = "busybox"
          command = ["sh", "-c", "chown -R 1000:1000 /usr/share/elasticsearch/data"]
          security_context {
            privileged = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/usr/share/elasticsearch/data"
          }
        }
        init_container {
          name    = "increase-vm-max-map"
          image   = "busybox"
          command = ["sysctl", "-w", "vm.max_map_count=262144"]
          security_context {
            privileged = true
          }
        }
        init_container {
          name    = "increase-fd-ulimit"
          image   = "busybox"
          command = ["sh", "-c", "ulimit -n 65536"]
          security_context {
            privileged = true
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "kibana" {
  metadata {
    namespace = kubernetes_namespace.logs.metadata[0].name
    name      = "kibana"
    labels = {
      "app" = "kibana"
    }
  }
  spec {
    port {
      port = 5601
    }
    selector = {
      "app" = "kibana"
    }
  }
}

resource "kubernetes_deployment" "kibana" {
  metadata {
    namespace = kubernetes_namespace.logs.metadata[0].name
    name      = "kibana"
    labels = {
      "app" = "kibana"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        "app" = "kibana"
      }
    }
    template {
      metadata {
        labels = {
          "app" = "kibana"
        }
      }
      spec {
        node_selector = {
          "az" = "az-2"
        }
        container {
          name  = "kibana"
          image = "docker.elastic.co/kibana/kibana:7.16.3"
          resources {
            limits = {
              cpu = "1000m"
            }
            requests = {
              cpu = "100m"
            }
          }
          env {
            name  = "ELASTICSEARCH_URL"
            value = "http://elasticsearch:9200"
          }
          port {
            container_port = 5601
          }
        }
      }
    }
  }
}

resource "kubernetes_service_account" "fluentd" {
  metadata {
    name      = "fluentd"
    namespace = kubernetes_namespace.logs.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "fluentd" {
  metadata {
    name = "fluentd"
    labels = {
      "app" = "fluentd"
    }
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces", "pods"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "fluentd" {
  metadata {
    name = "fluentd"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.fluentd.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.fluentd.metadata[0].name
    namespace = kubernetes_namespace.logs.metadata[0].name
  }
}

resource "kubernetes_daemonset" "fluentd" {
  metadata {
    name      = "fluentd"
    namespace = kubernetes_namespace.logs.metadata[0].name
    labels = {
      "app" = "fluentd"
    }
  }
  spec {
    selector {
      match_labels = {
        "app" = "fluentd"
      }
    }
    template {
      metadata {
        labels = {
          "app" = "fluentd"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.fluentd.metadata[0].name
        toleration {
          key    = "node-role.kubernetes.io/master"
          effect = "NoSchedule"
        }
        container {
          name  = "fluentd"
          image = "fluent/fluentd-kubernetes-daemonset:v1.4.2-debian-elasticsearch-1.1"
          env {
            name  = "FLUENT_ELASTICSEARCH_HOST"
            value = "${kubernetes_service.elasticsearch.metadata[0].name}.${kubernetes_namespace.logs.metadata[0].name}.svc.cluster.local"
          }
          env {
            name  = "FLUENT_ELASTICSEARCH_PORT"
            value = "9200"
          }
          env {
            name  = "FLUENT_ELASTICSEARCH_SCHEME"
            value = "http"
          }
          env {
            name  = "FLUENTD_SYSTEMD_CONF"
            value = "disable"
          }
          resources {
            limits = {
              "memory" = "512Mi"
            }
            requests = {
              "cpu"    = "100m"
              "memory" = "200Mi"
            }
          }
          volume_mount {
            name       = "varlog"
            mount_path = "/var/log"
          }
          volume_mount {
            name       = "varlibdockercontainers"
            mount_path = "/var/lib/docker/containers"
            read_only  = true
          }
        }
        termination_grace_period_seconds = 30
        volume {
          name = "varlog"
          host_path {
            path = "/var/log"
          }
        }
        volume {
          name = "varlibdockercontainers"
          host_path {
            path = "/var/lib/docker/containers"
          }
        }
      }
    }
  }
}

resource "aws_route53_record" "logs" {
  zone_id         = data.aws_route53_zone.hosting_zone.zone_id
  name            = "logs.${var.cluster_name}"
  type            = "CNAME"
  ttl             = "300"
  records         = [data.kubernetes_service.traefik.status.0.load_balancer.0.ingress.0.hostname]
  allow_overwrite = false
}

resource "kubernetes_ingress" "logs" {
  depends_on = [null_resource.local-exec, null_resource.local-exec-auth]
  metadata {
    namespace = kubernetes_namespace.logs.metadata[0].name
    name      = "logs"
    labels = {
      "app" = "logs"
    }
    annotations = {
      "cert-manager.io/cluster-issuer"                   = "letsencrypt-prod"
      "traefik.ingress.kubernetes.io/router.entrypoints" = "web,websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
      "traefik.ingress.kubernetes.io/router.middlewares" = "logs-basic-auth-logs@kubernetescrd"
    }
  }
  spec {
    ingress_class_name = kubernetes_ingress_class.traefik.metadata[0].name
    tls {
      hosts       = [aws_route53_record.logs.fqdn]
      secret_name = "logs-auth-tls"
    }
    rule {
      host = aws_route53_record.logs.fqdn
      http {
        path {
          backend {
            service_name = kubernetes_service.kibana.metadata[0].name
            service_port = 5601
          }
          path = "/"
        }
      }
    }

  }
}
