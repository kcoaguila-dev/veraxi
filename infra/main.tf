terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

resource "google_compute_instance" "staging_vm" {
  name         = "veraxi-staging"
  machine_type = var.machine_type
  zone         = var.zone

  # Applies network tags to allow web traffic if firewalls are configured
  tags = ["http-server", "https-server"]

  boot_disk {
    initialize_params {
      # Uses Google's Container-Optimized OS
      image = "cos-cloud/cos-stable"
      size  = 30
      type  = "pd-standard"
    }
  }

  network_interface {
    network = "default"

    # This empty access_config block ensures the VM gets a public IP address
    access_config {}
  }
}
