variable "azure_sub_id" {}
variable "azure_cli_id" {}
variable "azure_cli_secret" {}
variable "azure_tenant_id" {}

# Configure the Azure Provider
# Configure the Azure Provider
provider "azurerm" {
  subscription_id = "${var.azure_sub_id}"
  client_id       = "${var.azure_cli_id}"
  client_secret   = "${var.azure_cli_secret}"
  tenant_id       = "${var.azure_tenant_id}"
}

variable "rg_name" {
  default = "terraform_ceph"
}

variable "rg_location" {
  default = "eastasia"
}

variable "env_tag_name" {
  default = "testing"
}

variable "rc_count" {}

# Create a resource group
resource "azurerm_resource_group" "rg" {
  name     = "${var.rg_name}"
  location = "${var.rg_location}"
}

variable "vnet_name" {
  default = "terrafrom-ceph-vnet"
}

# Create a virtual network within the resource group
resource "azurerm_virtual_network" "vn" {
  name                = "${var.vnet_name}"
  address_space       = ["10.88.0.0/16"]
  location            = "${azurerm_resource_group.rg.location}"
  resource_group_name = "${azurerm_resource_group.rg.name}"
}

resource "azurerm_subnet" "subnet" {
  name                 = "terraform_subnet"
  resource_group_name  = "${azurerm_resource_group.rg.name}"
  virtual_network_name = "${azurerm_virtual_network.vn.name}"
  address_prefix       = "10.88.0.0/24"
}

variable "pubip_name" {
  default = "ceph_ip"
}

variable "domain_label" {}

resource "azurerm_public_ip" "pubip" {
  count                        = "${var.rc_count}"
  name                         = "${var.pubip_name}${count.index}"
  location                     = "${azurerm_resource_group.rg.location}"
  resource_group_name          = "${azurerm_resource_group.rg.name}"
  public_ip_address_allocation = "Static"
  idle_timeout_in_minutes      = 30
  domain_name_label            = "${var.domain_label}${count.index}"

  tags {
    environment = "${var.env_tag_name}"
  }
}

resource "azurerm_network_security_group" "nsg" {
  name                = "ceph_security_group"
  location            = "${azurerm_resource_group.rg.location}"
  resource_group_name = "${azurerm_resource_group.rg.name}"

  security_rule {
    name                       = "default-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

    security_rule {
    name                       = "ceph"
    priority                   = 500
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Any"
    source_port_range          = "*"
    destination_port_range     = "6800-7300"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "openVPN"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "9194"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags {
    environment = "${var.env_tag_name}"
  }
}

resource "azurerm_network_interface" "netface" {
  count                     = "${var.rc_count}"
  name                      = "ceph_net_interface_${count.index}"
  location                  = "${azurerm_resource_group.rg.location}"
  resource_group_name       = "${azurerm_resource_group.rg.name}"
  network_security_group_id = "${azurerm_network_security_group.nsg.id}"

  ip_configuration {
    name                          = "ceph_ip_conf"
    subnet_id                     = "${azurerm_subnet.subnet.id}"
    private_ip_address_allocation = "dynamic"
    public_ip_address_id          = "${element(azurerm_public_ip.pubip.*.id, count.index)}"
  }
}

resource "azurerm_managed_disk" "mandisk" {
  count                = "${var.rc_count}"
  name                 = "datadisk_existing_${count.index}"
  location             = "${azurerm_resource_group.rg.location}"
  resource_group_name  = "${azurerm_resource_group.rg.name}"
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = "100"
}

variable "vm_admin_user" {
  default = "amacsceph"
}

variable "vm_admin_pwd" {}

variable "vm_name" {
  default = "ceph_vpn"
}

variable "ovpn_svr_uname" {}

#variable "ovpn_svr_upwd" {}
variable "ovpn_svr_domain_or_ip" {}

variable "ovpn_cli_cfg_name" {}
variable "ssh_pri_key" {}
variable "ssh_keypub_path" {}
variable "ssh_keypri_path" {}

#variable "os_computer_name" {default="megatron"}

resource "azurerm_virtual_machine" "vm" {
  count                 = "${var.rc_count}"
  name                  = "${var.vm_name}${count.index}"
  location              = "${azurerm_resource_group.rg.location}"
  resource_group_name   = "${azurerm_resource_group.rg.name}"
  network_interface_ids = ["${element(azurerm_network_interface.netface.*.id, count.index)}"]
  vm_size               = "Standard_B2ms"

  # Uncomment this line to delete the OS disk automatically when deleting the VM
  delete_os_disk_on_termination = true

  # Uncomment this line to delete the data disks automatically when deleting the VM
  # delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04-LTS"
    version   = "latest"
  }
  storage_os_disk {
    name              = "os-disk${count.index}"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
  storage_data_disk {
    name            = "${element(azurerm_managed_disk.mandisk.*.name, count.index)}"
    managed_disk_id = "${element(azurerm_managed_disk.mandisk.*.id, count.index)}"
    create_option   = "Attach"
    lun             = 0
    disk_size_gb    = "${element(azurerm_managed_disk.mandisk.*.disk_size_gb, count.index)}"
  }
  os_profile {
    computer_name  = "${var.domain_label}${count.index}"
    admin_username = "${var.vm_admin_user}"
    admin_password = "${var.vm_admin_pwd}"
  }
  os_profile_linux_config {
    disable_password_authentication = false

    # disable_password_authentication = true

    ssh_keys = [{
      path     = "/home/${var.vm_admin_user}/.ssh/authorized_keys"
      key_data = "${file(var.ssh_keypub_path)}"
    }]
  }
  tags {
    environment = "${var.env_tag_name}"
  }
  connection {
    type = "ssh"
    host = "${var.domain_label}${count.index}.${var.rg_location}.cloudapp.azure.com"
    user = "${var.vm_admin_user}"

    password = "${var.vm_admin_pwd}"

    # private_key = "${file(var.ssh_keypri_path)}"
  }
  provisioner "remote-exec" {
    inline = [
      "printf 'Starting mounting data disk...\n'",
      "sudo sgdisk --new=0:0:0 /dev/sdc",
      "sudo mkfs.xfs -f /dev/sdc",
      "printf '[Unit]\nDescription=Mount for data storage\n[Mount]\nWhat=/dev/sdc\nWhere=/mnt/data\nType=xfs\nOptions=noatime\n[Install]\nWantedBy = multi-user.target \n' | sudo tee /etc/systemd/system/mnt-data.mount",
      "sudo systemctl start mnt-data.mount",
      "sudo systemctl enable mnt-data.mount",
      "printf 'starting setting up open vpn...'",
      "printf 'Step 12: Install the Client Configuration\n'",
      "sudo apt-get update",
      "sudo apt-get -y install openvpn",
      "echo ${var.ssh_pri_key} > ~/.ssh/id_rsa",
      "chmod og-rw ~/.ssh/id_rsa",
      "scp -P 9192 -o 'StrictHostKeyChecking no' ${var.ovpn_svr_uname}@${var.ovpn_svr_domain_or_ip}:client-configs/files/${var.ovpn_cli_cfg_name}${count.index}.ovpn ~/",
      "sed -i 's/# script-security/script-security/g' ~/${var.ovpn_cli_cfg_name}${count.index}.ovpn",
      "sed -i 's/# up/up/g' ~/${var.ovpn_cli_cfg_name}${count.index}.ovpn",
      "sed -i 's/# down/down/g' ~/${var.ovpn_cli_cfg_name}${count.index}.ovpn",
      "sudo openvpn --config ${var.ovpn_cli_cfg_name}${count.index}.ovpn --daemon",
    ]
  }
}

output "instance_ips" {
  value = ["${azurerm_public_ip.pubip.*.ip_address}"]
}
