locals {
  name   = var.name
  region = var.region
  azs    = slice(data.aws_availability_zones.available.names, 0, 2)

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/awslabs/data-on-eks"
  }

  eks_managed_node_groups = {
    core_node_group = {
      name        = "core-node-group"
      description = "EKS managed node group example launch template"
      # Filtering only Secondary CIDR private subnets starting with "100.". Subnet IDs where the nodes/node groups will be provisioned
      subnet_ids = compact([for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) :
        substr(cidr_block, 0, 4) == "100." ? subnet_id : null]
      )

      min_size     = 3
      max_size     = 9
      desired_size = 3

      instance_types = ["m5.xlarge"]

      labels = {
        WorkerType    = "ON_DEMAND"
        NodeGroupType = "core"
      }

      tags = {
        Name                     = "core-node-grp",
        "karpenter.sh/discovery" = local.name
      }
    }

    spark_ondemand_r5d = {
      name        = "spark-ondemand-r5d"
      description = "Spark managed node group for Driver pods"
      # Filtering only Secondary CIDR private subnets starting with "100.". Subnet IDs where the nodes/node groups will be provisioned
      subnet_ids = [element(compact([for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) :
        substr(cidr_block, 0, 4) == "100." ? subnet_id : null]), 0)
      ]

      min_size     = 1
      max_size     = 20
      desired_size = 1

      instance_types = ["r5d.xlarge"] # r5d.xlarge 4vCPU - 32GB - 1 x 150 NVMe SSD - Up to 10Gbps - Up to 4,750 Mbps EBS Bandwidth

      labels = {
        WorkerType    = "ON_DEMAND"
        NodeGroupType = "spark-on-demand-ca"
      }

      taints = [{
        key    = "spark-on-demand-ca",
        value  = true
        effect = "NO_SCHEDULE"
      }]

      tags = {
        Name          = "spark-ondemand-r5d"
        WorkerType    = "ON_DEMAND"
        NodeGroupType = "spark-on-demand-ca"
      }
    }

    # ec2-instance-selector --vcpus=48 --gpus 0 -a arm64 --allow-list '.*d.*'
    # This command will give you the list of the instances with similar vcpus for arm64 dense instances
    spark_spot_x86_48cpu = {
      name        = "spark-spot-48cpu"
      description = "Spark Spot node group for executor workloads"
      # Filtering only Secondary CIDR private subnets starting with "100.". Subnet IDs where the nodes/node groups will be provisioned
      subnet_ids = [element(compact([for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) :
        substr(cidr_block, 0, 4) == "100." ? subnet_id : null]), 0)
      ]

      min_size     = 1
      max_size     = 12
      desired_size = 1

      instance_types = ["r5d.12xlarge", "r6id.12xlarge", "c5ad.12xlarge", "c5d.12xlarge", "c6id.12xlarge", "m5ad.12xlarge", "m5d.12xlarge", "m6id.12xlarge"] # 48cpu - 2 x 1425 NVMe SSD

      labels = {
        WorkerType    = "SPOT"
        NodeGroupType = "spark-spot-ca"
      }

      taints = [{
        key    = "spark-spot-ca"
        value  = true
        effect = "NO_SCHEDULE"
      }]

      tags = {
        Name          = "spark-node-grp"
        WorkerType    = "SPOT"
        NodeGroupType = "spark"
      }
    }
  }
}

#---------------------------------------------------------------
# EKS Cluster
#---------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19"

  cluster_name    = local.name
  cluster_version = var.eks_cluster_version

  cluster_endpoint_public_access = true

  vpc_id = module.vpc.vpc_id
  # Filtering only Secondary CIDR private subnets starting with "100.". Subnet IDs where the EKS Control Plane ENIs will be created
  subnet_ids = compact([for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) :
    substr(cidr_block, 0, 4) == "100." ? subnet_id : null]
  )

  create_aws_auth_configmap = true
  manage_aws_auth_configmap = true
  aws_auth_roles = [
    # We need to add in the Karpenter node IAM role for nodes launched by Karpenter
    {
      rolearn  = module.eks_blueprints_addons.karpenter.node_iam_role_arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups = [
        "system:bootstrappers",
        "system:nodes",
      ]
    },
    {
      rolearn  = "arn:aws:iam::482649550366:role/AdministratorAccess"
      username = "Administrator"
      groups   = ["system:masters"]
    },
  ]

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
    # Allows Control Plane Nodes to talk to Worker nodes on all ports. Added this to simplify the example and further avoid issues with Add-ons communication with Control plane.
    # This can be restricted further to specific port based on the requirement for each Add-on e.g., metrics-server 4443, spark-operator 8080, karpenter 8443 etc.
    # Change this according to your security requirements if needed
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  eks_managed_node_group_defaults = {
    iam_role_additional_policies = {
      # Not required, but used in the example to access the nodes to inspect mounted volumes
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }

    # NVMe instance store volumes are automatically enumerated and assigned a device
    pre_bootstrap_user_data = <<-EOT
      cat <<-EOF > /etc/profile.d/bootstrap.sh
      #!/bin/sh

      # Configure NVMe volumes in RAID0 configuration
      # https://github.com/awslabs/amazon-eks-ami/blob/056e31f8c7477e893424abce468cb32bbcd1f079/files/bootstrap.sh#L35C121-L35C126
      # Mount will be: /mnt/k8s-disks
      export LOCAL_DISKS='raid0'
      EOF

      # Source extra environment variables in bootstrap script
      sed -i '/^set -o errexit/a\\nsource /etc/profile.d/bootstrap.sh' /etc/eks/bootstrap.sh
    EOT

    ebs_optimized = true
    # This bloc device is used only for root volume. Adjust volume according to your size.
    # NOTE: Don't use this volume for Spark workloads
    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size = 100
          volume_type = "gp3"
        }
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

  depends_on = [ module.eks ]

}
