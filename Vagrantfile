VM_NAME = ENV['VM_NAME'] || "default-hyperv-vm"
VM_MEM  = ENV['VM_MEMORY'] || "2048"
VM_MAX_MEM = ENV['VM_MAX_MEMORY'] || "10240"
VM_CPUS = ENV['VM_CPUS'] || "2"
VM_IP   = ENV['VM_IP'] || "192.168.0.10"
VM_BOX  = ENV['VM_BOX'] || "generic/ubuntu2204"
VM_BOX_VERSION = ENV['VM_BOX_VERSION'] || ""
VM_BOX_ARCHITECTURE = ENV['VM_BOX_ARCHITECTURE'] || "amd64"
VM_GW   = ENV['VM_GATEWAY'] || "192.168.0.1"
VM_SWITCH = ENV['VM_SWITCH'] || "VMSwitchNat"
VM_PROVISIONER = ENV['VM_PROVISIONER'] || "ubuntu"
VM_IP_TIMEOUT = (ENV['VM_IP_TIMEOUT'] || "120").to_i

unless %w[arch debian ubuntu].include?(VM_PROVISIONER)
  raise "VM_PROVISIONER non supportato: #{VM_PROVISIONER}"
end

Vagrant.configure("2") do |config|
  config.vm.box = VM_BOX
  config.vm.box_version = VM_BOX_VERSION unless VM_BOX_VERSION.empty?
  config.vm.box_architecture = VM_BOX_ARCHITECTURE
  config.vm.hostname = VM_NAME

  config.vm.provider "hyperv" do |hv|
    hv.cpus = VM_CPUS.to_i
    hv.memory = VM_MEM.to_i # In MB
    hv.maxmemory = VM_MAX_MEM.to_i
    hv.vmname = VM_NAME
    hv.ip_address_timeout = VM_IP_TIMEOUT
  end

  config.vm.network "private_network", bridge: VM_SWITCH
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provision "shell",
    path: "provisioners/#{VM_PROVISIONER}.sh",
    args: [VM_IP, VM_GW]
end