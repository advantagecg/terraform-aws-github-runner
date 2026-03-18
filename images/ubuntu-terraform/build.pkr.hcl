packer {
  required_plugins {
    amazon = {
      version = ">= 0.0.2"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

source "amazon-ebs" "githubrunner" {
  ami_name                                  = "github-runner-ubuntu-terraform-x86_64-${formatdate("YYYYMMDDhhmm", timestamp())}"
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
      OS_Version    = "ubuntu-terraform"
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

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive"
    ]
    inline = concat([
      # Wait for cloud-init to finish before touching apt
      "sudo cloud-init status --wait",

      # Base system update
      "sudo apt-get -y update",
      "sudo apt-get -y upgrade",
      "sudo apt-get -y install ca-certificates curl gnupg lsb-release",

      # Docker CE (official Docker repo)
      "sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg",
      "echo deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null",
      "sudo apt-get -y update",
      "sudo apt-get -y install docker-ce docker-ce-cli containerd.io",
      "sudo systemctl enable containerd.service",
      "sudo service docker start",
      "sudo usermod -a -G docker ubuntu",

      # Common DevOps tools
      "sudo apt-get -y install git curl wget jq unzip make build-essential",

      # AWS CLI v2
      "sudo curl -f https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip",
      "unzip awscliv2.zip",
      "sudo ./aws/install",
      "rm -rf awscliv2.zip aws",

      # Amazon CloudWatch agent
      "sudo curl -f https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -o amazon-cloudwatch-agent.deb",
      "sudo dpkg -i amazon-cloudwatch-agent.deb",
      "rm -f amazon-cloudwatch-agent.deb",

      # Node.js LTS (via NodeSource)
      "curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -",
      "sudo apt-get -y install nodejs",

      # Python 3 + pip + virtualenv
      "sudo apt-get -y install python3 python3-pip python3-venv",

      # tfenv + Terraform (latest)
      "git clone --depth=1 https://github.com/tfutils/tfenv.git /home/ubuntu/.tfenv",
      "sudo ln -s /home/ubuntu/.tfenv/bin/tfenv /usr/local/bin/tfenv",
      "sudo ln -s /home/ubuntu/.tfenv/bin/terraform /usr/local/bin/terraform",
      "tfenv install latest",
      "tfenv use latest",

      # Terragrunt (latest)
      "TERRAGRUNT_VERSION=$(curl -s https://api.github.com/repos/gruntwork-io/terragrunt/releases/latest | jq -r '.tag_name')",
      "sudo curl -fsSL https://github.com/gruntwork-io/terragrunt/releases/download/$${TERRAGRUNT_VERSION}/terragrunt_linux_amd64 -o /usr/local/bin/terragrunt",
      "sudo chmod +x /usr/local/bin/terragrunt",

      # tflint (latest)
      "curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | sudo bash",

      # terraform-docs (latest)
      "TFDOCS_VERSION=$(curl -s https://api.github.com/repos/terraform-docs/terraform-docs/releases/latest | jq -r '.tag_name')",
      "sudo curl -fsSL https://github.com/terraform-docs/terraform-docs/releases/download/$${TFDOCS_VERSION}/terraform-docs-$${TFDOCS_VERSION}-linux-amd64.tar.gz -o terraform-docs.tar.gz",
      "tar -xzf terraform-docs.tar.gz terraform-docs",
      "sudo mv terraform-docs /usr/local/bin/terraform-docs",
      "sudo chmod +x /usr/local/bin/terraform-docs",
      "rm -f terraform-docs.tar.gz",

      # Checkov (IaC security scanner)
      "sudo pip3 install checkov",

      # infracost (cost estimation)
      "curl -fsSL https://raw.githubusercontent.com/infracost/infracost/master/scripts/install.sh | sudo sh",
    ], var.custom_shell_commands)
  }

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
