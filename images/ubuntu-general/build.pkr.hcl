packer {
  required_plugins {
    amazon = {
      version = ">= 0.0.2"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

source "amazon-ebs" "githubrunner" {
  ami_name                                  = "github-runner-ubuntu-general-x86_64-${formatdate("YYYYMMDDhhmm", timestamp())}"
  instance_type                             = var.instance_type
  iam_instance_profile                      = var.iam_instance_profile
  region                                    = var.region
  security_group_id                         = var.security_group_id
  subnet_id                                 = var.subnet_id
  associate_public_ip_address               = var.associate_public_ip_address
  temporary_security_group_source_public_ip = var.temporary_security_group_source_public_ip

  source_ami_filter {
    filters = {
      name                = "*ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }
  ssh_username = "ubuntu"
  tags = merge(
    var.global_tags,
    var.ami_tags,
    {
      OS_Version    = "ubuntu-general"
      Release       = "Latest"
      Base_AMI_Name = "{{ .SourceAMIName }}"
  })
  snapshot_tags = merge(
    var.global_tags,
    var.snapshot_tags,
  )

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = var.ebs_delete_on_termination
  }
}

build {
  name = "githubactions-runner"
  sources = [
    "source.amazon-ebs.githubrunner"
  ]

  # -------------------------------------------------------------------
  # Block 1: Add apt repos + install all packages
  # -------------------------------------------------------------------
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive"
    ]
    inline = concat([
      # Wait for cloud-init before touching apt
      "sudo cloud-init status --wait",

      # Base update + repo prerequisites
      "sudo apt-get -y update",
      "sudo apt-get -y upgrade",
      "sudo apt-get -y install ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common",

      # --- Docker repo ---
      "sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null",

      # --- NodeSource repo (LTS) ---
      "curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -",

      # --- Google Chrome repo ---
      "sudo curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg",
      "echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] https://dl.google.com/linux/chrome/deb/ stable main\" | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null",

      # --- Microsoft repo (mssql-tools) ---
      "sudo curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft-keyring.gpg",
      "echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-keyring.gpg] https://packages.microsoft.com/ubuntu/22.04/prod jammy main\" | sudo tee /etc/apt/sources.list.d/mssql-release.list > /dev/null",

      # --- CommandBox repo (CFML) ---
      "sudo curl -fsSL https://downloads.ortussolutions.com/debs/gpg | sudo gpg --dearmor -o /usr/share/keyrings/ortus-keyring.gpg",
      "echo \"deb [signed-by=/usr/share/keyrings/ortus-keyring.gpg] https://downloads.ortussolutions.com/debs/noarch /\" | sudo tee /etc/apt/sources.list.d/commandbox.list > /dev/null",

      # Final apt update after all repos added
      "sudo apt-get -y update",

      # --- Install all packages ---
      "sudo apt-get -y install ack acpid apt-transport-https byobu build-essential",
      "sudo apt-get -y install containerd.io curl",
      "sudo apt-get -y install docker-buildx-plugin docker-ce docker-ce-cli docker-compose-plugin",
      "sudo apt-get -y install eatmydata ec2-instance-connect expect",
      "sudo apt-get -y install freetds-dev fuse3",
      "sudo apt-get -y install git git-lfs gnupg google-chrome-stable",
      "sudo apt-get -y install jq libeatmydata1 libfuse3-3 libsodium23",
      "sudo apt-get -y install libssl-dev libvips-dev libwrap0 libxml2-dev libxss1 libyaml-dev",
      "sudo apt-get -y install make nano nodejs",
      "sudo apt-get -y install openjdk-11-jre openssh-server openssh-sftp-server",
      "sudo apt-get -y install postgresql-client",
      "sudo apt-get -y install python3 python3-jinja2 python3-pip python3-setuptools python3-venv",
      "sudo apt-get -y install ruby-dev ssh-import-id",
      "sudo apt-get -y install unixodbc-dev unzip wget zip zlib1g-dev",

      # mssql-tools requires EULA acceptance
      "sudo ACCEPT_EULA=Y apt-get install -y mssql-tools",

      # CommandBox
      "sudo apt-get -y install commandbox",
    ], var.custom_shell_commands)
  }

  # -------------------------------------------------------------------
  # Block 2: Binary installers (AWS CLI, CloudWatch agent, SSM plugin)
  # -------------------------------------------------------------------
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive"
    ]
    inline = [
      # AWS CLI v2
      "sudo curl -f https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip",
      "unzip awscliv2.zip",
      "sudo ./aws/install",
      "rm -rf awscliv2.zip aws",

      # Amazon CloudWatch agent
      "sudo curl -f https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -o amazon-cloudwatch-agent.deb",
      "sudo dpkg -i amazon-cloudwatch-agent.deb",
      "rm -f amazon-cloudwatch-agent.deb",

      # AWS Session Manager plugin
      "sudo curl -f https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb -o session-manager-plugin.deb",
      "sudo dpkg -i session-manager-plugin.deb",
      "rm -f session-manager-plugin.deb",
    ]
  }

  # -------------------------------------------------------------------
  # Block 3: Docker service setup
  # -------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "sudo systemctl enable containerd.service",
      "sudo service docker start",
      "sudo usermod -a -G docker ubuntu",
    ]
  }

  # -------------------------------------------------------------------
  # Block 4: rbenv + Ruby + yard gem
  # -------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      # Clone rbenv and ruby-build into ubuntu home
      "git clone https://github.com/rbenv/rbenv.git /home/ubuntu/.rbenv",
      "git clone https://github.com/rbenv/ruby-build.git /home/ubuntu/.rbenv/plugins/ruby-build",

      # Add rbenv to PATH for interactive shells
      "echo 'export PATH=\"$HOME/.rbenv/bin:$PATH\"' >> /home/ubuntu/.bashrc",
      "echo 'eval \"$(rbenv init -)\"' >> /home/ubuntu/.bashrc",

      # Symlink rbenv binary for non-interactive use (e.g. runner scripts)
      "sudo ln -s /home/ubuntu/.rbenv/bin/rbenv /usr/local/bin/rbenv",

      # Install latest stable Ruby via rbenv
      "RUBY_VERSION=$(/home/ubuntu/.rbenv/bin/rbenv install -l | grep -v - | tail -1 | tr -d ' ') && /home/ubuntu/.rbenv/bin/rbenv install $RUBY_VERSION && /home/ubuntu/.rbenv/bin/rbenv global $RUBY_VERSION",

      # Install yard gem
      "/home/ubuntu/.rbenv/shims/gem install yard",

      # Fix ownership
      "sudo chown -R ubuntu:ubuntu /home/ubuntu/.rbenv",
    ]
  }

  # -------------------------------------------------------------------
  # GitHub Actions runner install
  # -------------------------------------------------------------------
  provisioner "file" {
    content = templatefile("../install-runner.sh", {
      install_runner = templatefile("../../modules/runners/templates/install-runner.sh", {
        ARM_PATCH                       = ""
        S3_LOCATION_RUNNER_DISTRIBUTION = ""
        RUNNER_ARCHITECTURE             = "x64"
      })
    })
    destination = "/tmp/install-runner.sh"
  }

  provisioner "shell" {
    environment_vars = [
      "RUNNER_TARBALL_URL=https://github.com/actions/runner/releases/download/v${local.runner_version}/actions-runner-linux-x64-${local.runner_version}.tar.gz"
    ]
    inline = [
      "sudo chmod +x /tmp/install-runner.sh",
      "echo ubuntu | tee -a /tmp/install-user.txt",
      "sudo RUNNER_ARCHITECTURE=x64 RUNNER_TARBALL_URL=$RUNNER_TARBALL_URL /tmp/install-runner.sh",
      "echo ImageOS=ubuntu22 | tee -a /opt/actions-runner/.env"
    ]
  }

  provisioner "file" {
    content = templatefile("../start-runner.sh", {
      start_runner = templatefile("../../modules/runners/templates/start-runner.sh", { metadata_tags = "enabled" })
    })
    destination = "/tmp/start-runner.sh"
  }

  provisioner "shell" {
    inline = [
      "sudo mv /tmp/start-runner.sh /var/lib/cloud/scripts/per-boot/start-runner.sh",
      "sudo chmod +x /var/lib/cloud/scripts/per-boot/start-runner.sh",
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
