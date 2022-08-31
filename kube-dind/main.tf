terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "0.4.9"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.12.1"
    }
  }
}

variable "use_kubeconfig" {
  type        = bool
  sensitive   = true
  default = false
  description = <<-EOF
  Use host kubeconfig? (true/false)

  Set this to false if the Coder host is itself running as a Pod on the same
  Kubernetes cluster as you are deploying workspaces to.

  Set this to true if the Coder host is running outside the Kubernetes cluster
  for workspaces.  A valid "~/.kube/config" must be present on the Coder host.
  EOF
}

variable "namespace" {
  type        = string
  sensitive   = true
  description = "The namespace to create workspaces in (must exist prior to creating workspaces)"
  default     = "coder"
}

variable "home_disk_size" {
  type        = number
  description = "How large would you like your home volume to be (in GB)?"
  default     = 10
  validation {
    condition     = var.home_disk_size >= 1
    error_message = "Value must be greater than or equal to 1."
  }
}

provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

data "coder_workspace" "me" {}

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"

  env = {
    GIT_AUTHOR_NAME     = "${data.coder_workspace.me.owner}"
    GIT_COMMITTER_NAME  = "${data.coder_workspace.me.owner}"
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace.me.owner_email}"
    GIT_COMMITTER_EMAIL = "${data.coder_workspace.me.owner_email}"
  }

  startup_script = <<EOT
    #!/bin/bash

    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh  | tee code-server-install.log
    code-server --auth none --port 13337 | tee code-server-install.log &
    set -eux
    # Sleep for a good long while before exiting.
    # This is to allow folks to exec into a failed workspace and poke around to
    # troubleshoot.
    waitonexit() {
      echo "=== Agent script exited with non-zero code. Sleeping 24h to preserve logs..."
      sleep 86400
    }
    BINARY_DIR="/tmp/coder-agent"
    mkdir -p $BINARY_DIR
    BINARY_NAME="coder-linux-amd64"
    
    cd "$BINARY_DIR"

    # Attempt to download the coder agent.
    # This could fail for a number of reasons, many of which are likely transient.
    # So just keep trying!
    while :; do
      # Try a number of different download tools, as we don not know what we
      # will have available.
      status=""
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL --compressed "$BINARY_URL" -o "$BINARY_NAME" && break
        status=$?
      elif command -v wget >/dev/null 2>&1; then
        wget -q "$BINARY_URL" -O "$BINARY_NAME" && break
        status=$?
      elif command -v busybox >/dev/null 2>&1; then
        busybox wget -q "$BINARY_URL" -O "$BINARY_NAME" && break
        status=$?
      else
        echo "error: no download tool found, please install curl, wget or busybox wget"
        exit 127
      fi
      echo "error: failed to download coder agent"
      echo " command returned: $status"
      echo "Trying again in 30 seconds..."
      sleep 30
    done

    if ! chmod +x $BINARY_NAME; then
      echo "Failed to make $BINARY_NAME executable"
      exit 1
    fi

    exec ./$BINARY_NAME agent
  EOT

}

# code-server
resource "coder_app" "code-server" {
  agent_id      = coder_agent.main.id
  name          = "code-server"
  icon          = "/icon/code.svg"
  url           = "http://localhost:13337?folder=/home/coder"
  relative_path = true
}

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}-home"
    namespace = var.namespace
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${var.home_disk_size}Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "dind" {
  metadata {
    name      = "dind-storage-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}"
    namespace = var.namespace
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}"
    namespace = var.namespace
  }
  
  spec {

    container {
      name    = "dev"
      image   = "codercom/enterprise-base:ubuntu"
      command = ["sh", "-c", coder_agent.main.startup_script]
      
      security_context {
        run_as_user = "1000"      
        }
      
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      env {
        name  = "CODER_AGENT_URL"
        value = "http://coder.${namespace}.svc.cluster.local/"
      }

      env {
        name  = "BINARY_URL"
        value = "http://coder.${namespace}.svc.cluster.local/bin/coder-linux-amd64"
      }

      env {
        name = "DOCKER_HOST"
        value = "tcp://localhost:2375"
      }

      volume_mount {
        mount_path = "/home/coder"
        name       = "home"
        read_only  = false
      }
    }

    container {
	    name = "docker-dind"
	    image = "docker:dind"
	    security_context {
	      privileged = true
	    }
      command = ["dockerd", "--host", "tcp://127.0.0.1:2375"]
	    volume_mount {
	      name = "dind-storage"
	      mount_path = "/var/lib/docker"
	    }
    }

    volume {
        name = "home"
        persistent_volume_claim {
          claim_name = kubernetes_persistent_volume_claim.home.metadata.0.name
          read_only  = false
        }
    }
    volume {
        name = "dind-storage"
        persistent_volume_claim {
          claim_name = kubernetes_persistent_volume_claim.dind.metadata.0.name
          read_only  = false
        }
    }
  }
}
