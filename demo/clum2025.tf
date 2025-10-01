#################### Provider ####################
# To use the OpenStack provider, we need to specify the provider block
terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "3.3.2"
    }
  }
}


#################### Variables ####################
variable "name_prefix" {
  type    = string
  default = "clum-demo-sanjay"
}

variable "public_key" {
  type = map(any)
  default = {
    name   = "sanjay_denbi_cloud_key_clum2025"
    pubkey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBP8ipFe46JUjl+zHcTh8/7A3kDCGyBzQqIFSVUKXTWwU+rWj1A8VX8MWiOap6/mY+UuOXfJ2SDrLGkjpc/fdy10= sanjay"
  }
}

variable "image_name" {
  type    = string
  default = "Ubuntu 24.04 LTS (2025-07-11)"
}

variable "flavor_name" {
  type    = string
  default = "de.NBI tiny"
}

variable "volume_size" {
  type    = number
  default = 20
}

variable "floatingip_pool" {
  type    = string
  default = "external"
}


#################### Images ####################
# # Note: To upload an image to OpenStack cloud
# # Since multiple images are already present in the cloud, we can ignore this step
# resource "openstack_images_image_v2" "cloud-image" {
#   name             = "RancherOS"
#   image_source_url = "<https://releases.rancher.com/os/latest/rancheros-openstack.img>"  # CHANGE URL
#   container_format = "bare"
#   disk_format      = "qcow2"
# }


#################### Key Pairs ####################
# To create a key pair, so that we can ssh into the instance later
resource "openstack_compute_keypair_v2" "my-cloud-key" {
  name       = var.public_key["name"]
  public_key = var.public_key["pubkey"]
}

# # If the key pair is already present in the cloud, we can use data block to fetch it
# data "openstack_compute_keypair_v2" "my-cloud-key" {
#   name = var.public_key["name"]
# }

###################### Network Lookup ####################
# Fetch the network details using data block. Here we are using an existing network.
data "openstack_networking_network_v2" "clum-demo_net" {
  name = "CLUM20251_net"
}


#################### Security Groups ####################
# Lets create a couple of security groups and rules to allow SSH and outgoing connections
resource "openstack_networking_secgroup_v2" "net-ssh-public" {
  name                 = "${var.name_prefix}_ssh_public"
  description          = "[TF] Allow SSH connections from anywhere"
  delete_default_rules = "true"
}

resource "openstack_networking_secgroup_rule_v2" "rule-ssh-public" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  security_group_id = openstack_networking_secgroup_v2.net-ssh-public.id
}

resource "openstack_networking_secgroup_v2" "net-egress-public" {
  name                 = "${var.name_prefix}_egress_public"
  description          = "[TF] Allow any outgoing connection"
  delete_default_rules = true
}

resource "openstack_networking_secgroup_rule_v2" "rule-egress-public" {
  direction         = "egress"
  ethertype         = "IPv4"
  security_group_id = openstack_networking_secgroup_v2.net-egress-public.id
}


###################### Network Port ####################
# Create a port on the network (assume it as a virtual NIC)
resource "openstack_networking_port_v2" "clum-demo-port" {
  name       = "${var.name_prefix}_port"
  network_id = data.openstack_networking_network_v2.clum-demo_net.id

  security_group_ids = [
    openstack_networking_secgroup_v2.net-ssh-public.id,
    openstack_networking_secgroup_v2.net-egress-public.id,
  ]
}


###################### VM Provisioning ####################
# Lets get the latest ubuntu image id using data block
data "openstack_images_image_v2" "ubuntu" {
  name        = var.image_name
  most_recent = true
}

# Lets create an instance
resource "openstack_compute_instance_v2" "clum-demo" {
  name        = "${var.name_prefix}_instance"
  flavor_name = var.flavor_name
  image_id    = data.openstack_images_image_v2.ubuntu.id
  key_pair    = openstack_compute_keypair_v2.my-cloud-key.name

  # Attach the created port (including security groups)
  network {
    port = openstack_networking_port_v2.clum-demo-port.id
  }

  # Optional: Via Cloud-Init, we can run some commands at the first boot
  # Here we are formatting and mounting the attached volume to /data directory
  user_data = <<-EOF
    #cloud-config
    bootcmd:
        - test -z "$(blkid /dev/vdc)" && mkfs -t ext4 -L ubuntu /dev/vdc
        - mkdir -p /data
    mounts:
        - ["/dev/vdc", "/data", auto, "defaults,nofail", "0", "2"]
    runcmd:
        - [ chown, "ubuntu.ubuntu", -R, /data ]
  EOF
}


#################### Volumes ####################
# Create a volume and attach it to the instance
resource "openstack_blockstorage_volume_v3" "clum-demo_volume" {
  name        = "${var.name_prefix}_volume"
  size        = var.volume_size
  description = "A volume for the clum-demo instance"
}

# Attach the created volume to the instance at /dev/vdc
resource "openstack_compute_volume_attach_v2" "volume_attachment" {
  instance_id = openstack_compute_instance_v2.clum-demo.id
  volume_id   = openstack_blockstorage_volume_v3.clum-demo_volume.id
  device      = "/dev/vdc"
}


#################### Floating IPs ####################
# Create a floating IP from the external network pool
resource "openstack_networking_floatingip_v2" "floating_ip" {
  pool = var.floatingip_pool

  # lifecycle {
  #   prevent_destroy = true
  # }
}

# Attach our floating IP to the instance
resource "openstack_networking_floatingip_associate_v2" "float_ip_assoc" {
  floating_ip = openstack_networking_floatingip_v2.floating_ip.address
  port_id     = openstack_networking_port_v2.clum-demo-port.id

  # lifecycle {
  #   prevent_destroy = true
  # }
}


#################### Outputs ####################
# Output the IP address attached to our resource
output "clum-demo_instance_floating_ip" {
  value = openstack_networking_floatingip_v2.floating_ip.address
}
