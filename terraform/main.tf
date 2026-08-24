terraform {
  required_version = ">= 1.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.53"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.10"
    }
  }
}

provider "openstack" {
  cloud = "openstack"
}

############################
# APP DEFAULTS (defined by the app developer)
############################

locals {
  app_name = "jupyter-notebook"
  flavor   = "gp1.small"
  key_pair = "" # empty = password auth only

  # Addresses are publicly routed, so the fixed address is reachable
  # on its own - and a floating IP cannot be attached there at all.
  enable_floating_ip = false

  # Who may reach the notebook on 8000. Campus and VPN only: the token travels
  # over plain HTTP.
  web_source_cidr = "141.72.0.0/16"

  metadata = {}
}

############################
# USER MANAGEMENT (CONTRACT)
############################

# Flatten users from teams - exactly as specified by the contract
locals {
  all_users = flatten([
    for team, members in var.users : [
      for member in members : {
        id       = "${team}-${replace(split("@", member.email)[0], ".", "-")}"
        team     = team
        email    = member.email
        username = replace(split("@", member.email)[0], ".", "")
      }
    ]
  ])

  unique_teams = distinct([for user in local.all_users : user.team])

  usernames = [for user in local.all_users : user.username]

  # Map for fast lookups
  users_map    = { for user in local.all_users : user.id => user }
  teams_list   = distinct([for user in local.all_users : user.team])
  user_indices = { for idx, user in local.all_users : user.id => idx }
}

# Generate passwords for each user
resource "random_password" "user_passwords" {
  count       = length(local.all_users)
  length      = 16
  special     = true
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
  min_special = 1
}

locals {
  # [CONTRACT] User accounts output (online IDE compatible)
  user_accounts = length(local.all_users) > 0 ? {
    for uid, user in local.users_map : uid => {
      type     = "password"
      ip       = local.enable_floating_ip ? openstack_networking_floatingip_v2.fip[0].address : openstack_compute_instance_v2.shared_vm.network[0].fixed_ip_v4
      port     = 8000
      username = user.username
      auth     = random_password.user_passwords[local.user_indices[uid]].result
    }
  } : {}
}

# Packer-built image lookup by name (avoid hardcoding IDs)
data "openstack_images_image_v2" "image" {
  name        = var.image_name
  most_recent = true
}

# External network only required when floating IP is enabled
data "openstack_networking_network_v2" "external" {
  name = var.floating_ip_pool
}

resource "random_id" "suffix" {
  byte_length = 4
}

# -----------------------------------------------------------------------------
# Shared instance (one VM for all users)
# -----------------------------------------------------------------------------
resource "openstack_compute_instance_v2" "shared_vm" {
  name        = "${local.app_name}-shared"
  image_id    = data.openstack_images_image_v2.image.id
  flavor_name = local.flavor
  key_pair    = local.key_pair != "" ? local.key_pair : null

  # This argument takes group *names*, not IDs - see security_group.tf.
  security_groups = [
    var.shared_secgroup_id,
    openstack_networking_secgroup_v2.notebook.name,
  ]

  timeouts {
    create = "15m"
    delete = "15m"
  }

  network {
    uuid = var.network_uuid
  }

  user_data = templatefile("${path.module}/cloud-init-multi-user.yml.tpl", {
    all_users    = local.all_users
    unique_teams = local.unique_teams
    passwords    = [for p in random_password.user_passwords : p.result]
  })

  metadata = merge(local.metadata, {
    teams = join(",", local.unique_teams)
    users = join(",", local.usernames)
  })
}

# -----------------------------------------------------------------------------
# Optional floating IP (one for the shared VM)
# -----------------------------------------------------------------------------
resource "openstack_networking_floatingip_v2" "fip" {
  count = local.enable_floating_ip ? 1 : 0
  pool  = data.openstack_networking_network_v2.external.name
}

# Wait for VM to fully boot before looking up its port
resource "time_sleep" "wait_for_vm" {
  count           = local.enable_floating_ip ? 1 : 0
  depends_on      = [openstack_compute_instance_v2.shared_vm]
  create_duration = "60s"
}

# Look up the VM port ID
data "openstack_networking_port_v2" "vm_port" {
  count     = local.enable_floating_ip ? 1 : 0
  device_id = openstack_compute_instance_v2.shared_vm.id
  depends_on = [
    openstack_compute_instance_v2.shared_vm,
    time_sleep.wait_for_vm
  ]
}

# Associate floating IP using port ID from data source
resource "openstack_networking_floatingip_associate_v2" "fip_assoc" {
  count       = local.enable_floating_ip ? 1 : 0
  floating_ip = openstack_networking_floatingip_v2.fip[0].address
  port_id     = data.openstack_networking_port_v2.vm_port[0].id

  depends_on = [
    data.openstack_networking_port_v2.vm_port,
    time_sleep.wait_for_vm
  ]
}
