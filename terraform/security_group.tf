# Security group for the notebook port.
#
# ``shared_secgroup_id`` defaults to the App Store host's own group, which opens
# 22, 80 and 443. JupyterHub listens on 8000, so without the group below the
# deployment succeeds in every visible way and every URL it hands out times out.
#
# NOTE ON THE ARGUMENT NAME
# openstack_compute_instance_v2.security_groups takes group *names*;
# openstack_networking_port_v2.security_group_ids takes IDs. This App attaches
# groups to the instance, so ``.name`` is what belongs in main.tf - passing an
# ID there is accepted by Nova only as a legacy convenience.

resource "random_id" "secgroup" {
  byte_length = 4
}

resource "openstack_networking_secgroup_v2" "notebook" {
  # Suffixed because Neutron permits duplicate group names, and several
  # deployments of this App can be live at once.
  name        = "${local.app_name}-${random_id.secgroup.hex}"
  description = "JupyterHub web UI"
}

resource "openstack_networking_secgroup_rule_v2" "notebook" {
  security_group_id = openstack_networking_secgroup_v2.notebook.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8000
  port_range_max    = 8000
  remote_ip_prefix  = local.web_source_cidr
  description       = "JupyterHub web UI (campus/VPN only)"
}

# IPv6 counterpart: network_uuid now defaults to DHBWV6 (dual-stack), so the
# instance gets a v6 address too — without this second rule, the DHBW VPN's
# IPv6-only route to OpenStack instances (see Ubuntu-App/packer's
# ssh_ip_version comment) would have no way to reach port 8000 at all.
# Security-group rules are per-ethertype, so IPv4 and IPv6 each need their
# own rule even on the same dual-stack network.
resource "openstack_networking_secgroup_rule_v2" "notebook_v6" {
  security_group_id = openstack_networking_secgroup_v2.notebook.id
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 8000
  port_range_max    = 8000
  remote_ip_prefix  = "::/0"
  description       = "JupyterHub web UI (IPv6)"
}
