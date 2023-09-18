module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.15"

  cluster_name    = local.name
  cluster_version = var.eks_cluster_version

  cluster_endpoint_private_access = true # if true, Kubernetes API requests within your cluster's VPC (such as node to control plane communication) use the private VPC endpoint
  cluster_endpoint_public_access  = true # if true, Your cluster API server is accessible from the internet. You can, optionally, limit the CIDR blocks that can access the public endpoint.

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  manage_aws_auth_configmap = false
  # create_aws_auth_configmap = false

  #---------------------------------------
  # Note: This can further restricted to specific required for each Add-on and your application
  #---------------------------------------
  # Extend cluster security group rules
  cluster_security_group_additional_rules = {
    ingress_nodes_ephemeral_ports_tcp = {
      description                = "Nodes on ephemeral ports"
      protocol                   = "tcp"
      from_port                  = 1025
      to_port                    = 65535
      type                       = "ingress"
      source_node_security_group = true
    }
  }

  # Extend node-to-node security group rules
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  eks_managed_node_group_defaults = {
    iam_role_additional_policies = {
      # Not required, but used in the example to access the nodes to inspect mounted volumes
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }

}

locals {

  node_iam_role_arns = concat([for group in module.eks_managed_node_groups : group.iam_role_arn])

  aws_auth_roles = [
    {
      rolearn  = "arn:aws:iam::482649550366:role/AdministratorAccess"
      username = "Administrator"
      groups   = ["system:masters"]
    },
  ]

  aws_auth_configmap_data = {
    mapRoles = yamlencode(concat(
      [for role_arn in local.node_iam_role_arns : {
        rolearn  = role_arn
        username = "system:node:{{EC2PrivateDNSName}}"
        groups = [
          "system:bootstrappers",
          "system:nodes",
        ]
        }
      ],
      local.aws_auth_roles
    ))
    # mapUsers    = yamlencode(var.aws_auth_users)
    # mapAccounts = yamlencode(var.aws_auth_accounts)
    mapUsers    = yamlencode({})
    mapAccounts = yamlencode({})
  }

  disabled_eks_managed_node_groups = {}

  eks_managed_node_groups = {

    doeks_node_group = {
      name        = "doeks-node-group"
      description = "EKS managed node group example launch template"

      ami_id = data.aws_ami.eks.image_id
      # This will ensure the bootstrap user data is used to join the node
      # By default, EKS managed node groups will not append bootstrap script;
      # this adds it back in using the default template provided by the module
      # Note: this assumes the AMI provided is an EKS optimized AMI derivative
      enable_bootstrap_user_data = true

      # Optional - This is to show how you can pass pre bootstrap data
      pre_bootstrap_user_data = <<-EOT
        echo "Node bootstrap process started by Data on EKS"
      EOT

      # Optional - Post bootstrap data to verify anything
      post_bootstrap_user_data = <<-EOT
        echo "Bootstrap complete.Ready to Go!"
      EOT

      subnet_ids = module.vpc.private_subnets

      min_size     = 1
      max_size     = 9
      desired_size = 1

      force_update_version = true
      instance_types       = ["m5.xlarge"]

      ebs_optimized = true
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 100
            volume_type = "gp3"
          }
        }
      }

      labels = {
        WorkerType    = "ON_DEMAND"
        NodeGroupType = "doeks"
      }

      tags = {
        Name = "doeks-node-grp"
      }
    }
  }
}

module "eks_managed_node_groups" {

  source = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "~> 19"

  for_each = local.eks_managed_node_groups

  name            = each.value.name
  cluster_name    = module.eks.cluster_name
  cluster_version = module.eks.cluster_version

  ami_id          = each.value.ami_id

  enable_bootstrap_user_data = true

  subnet_ids      = each.value.subnet_ids

  // The following variables are necessary if you decide to use the module outside of the parent EKS module context.
  // Without it, the security groups of the nodes are empty and thus won't join the cluster.
  cluster_primary_security_group_id = module.eks.cluster_primary_security_group_id
  vpc_security_group_ids            = [module.eks.node_security_group_id]

  min_size     = each.value.min_size
  max_size     = each.value.max_size
  desired_size = each.value.desired_size

  instance_types = each.value.instance_types

  labels = contains(keys(each.value), "labels") ? each.value.labels : {}
  taints = contains(keys(each.value), "taints") ? each.value.taints : []
  tags   = contains(keys(each.value), "tags") ? each.value.tags : {}

  # depends_on = [ kubernetes_config_map_v1_data.aws_auth ]

}

resource "kubernetes_config_map" "aws_auth" {

  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = local.aws_auth_configmap_data

  lifecycle {
    # We are ignoring the data here since we will manage it with the resource below
    # This is only intended to be used in scenarios where the configmap does not exist
    ignore_changes = [data, metadata[0].labels, metadata[0].annotations]
  }

  depends_on = [ module.eks_managed_node_groups.aws_iam_role ]
}

resource "kubernetes_config_map_v1_data" "aws_auth" {
  force = true

  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = local.aws_auth_configmap_data

  depends_on = [
    # Required for instances where the configmap does not exist yet to avoid race condition
    kubernetes_config_map.aws_auth,
  ]
}
