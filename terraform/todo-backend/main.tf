
// Create new namespace 
resource "kubernetes_namespace" "todo_backend" {
  metadata {
    name = "${var.environment}-todo-backend${var.namespace_suffix}"
    //name = "arga"
  }
}

// Create service account
resource "google_service_account" "todo_account" {
  depends_on = ["kubernetes_namespace.todo_backend"]

  account_id   = "${kubernetes_namespace.todo_backend.metadata.0.name}"

  display_name = "Todo Backend service account in ${var.environment} "
  // Run local-exec because terraform as 0.10 doesn't have a way to export it
  // https://github.com/terraform-providers/terraform-provider-google/pull/204
  provisioner "local-exec" {
       command = "gcloud --project ${var.google_project} container clusters get-credentials ${data.terraform_remote_state.gke.name}; gcloud beta iam service-accounts keys create --iam-account ${google_service_account.todo_account.email} service-account.json; kubectl --namespace ${kubernetes_namespace.todo_backend.metadata.0.name} create secret generic google-service-account --from-file service-account.json; echo rm service-account.json"
  }
  provisioner "local-exec" {
    when    = "destroy"
    command = "gcloud --project ${var.google_project} container clusters get-credentials ${data.terraform_remote_state.gke.name}; kubectl --namespace ${kubernetes_namespace.todo_backend.metadata.0.name} delete secret google-service-account"
  }
}

#resource "google_project_iam_member" "datastore_viewer" {
#   role    = "roles/datastore.viewer"
#  member  = "serviceAccount:${google_service_account.todo_account.email}"
#}

resource "google_project_iam_member" "datastore_user" {
   role    = "roles/datastore.user"
   member  = "serviceAccount:${google_service_account.todo_account.email}"
   # Check if https://github.com/terraform-providers/terraform-provider-google/pull/1197 
   # fix our timing issues
   #provisioner "local-exec" {
   #    command = "echo sleep 90s to propagate all permissions; sleep 90"
   # }
}


// Create Pod in mode == pod
resource "kubernetes_pod" "test" {
  depends_on = ["google_project_iam_member.datastore_user"]
  count = "${var.mode=="pod" ? 1 : 0}"
  metadata {
    name = "todo-backend-${var.version}"
    namespace = "${kubernetes_namespace.todo_backend.metadata.0.name}"
  }

  spec {
    restart_policy = "Never"
    container {
      image = "${var.registry_host}/${var.google_project}/node-todo-backend:${var.version}"
      name  = "node-backend"
      command = ["./runtest"]
      args = [["--fast"]]
      env = [ { name="NODE_ENV" value="${var.environment}"},
              { name="GOOGLE_DATASTORE_NAMESPACE" value="${kubernetes_namespace.todo_backend.metadata.0.name}-${var.version}"},
              { name="GOOGLE_PROJECT_ID" value="${var.google_project}"},
              { name="GOOGLE_APPLICATION_CREDENTIALS" value="/var/run/secrets/cloud.google.com/service-account.json"}
            ]
      volume_mount = [ {name="google-service-account" mount_path="/var/run/secrets/cloud.google.com"}]            
    }
    volume = [ { name="google-service-account" secret={secret_name="google-service-account"}} ]

  }
  provisioner "local-exec" { // To ensure that we can connect with kubectl outside terraform directly afterwards
    command = "gcloud --project ${var.google_project} container clusters get-credentials ${data.terraform_remote_state.gke.name}"
  }
}
  
// Create deployment, service in mode==deployment

// Create inbound services
resource "kubernetes_service" "todo_backend" {
#  count = "${var.mode=="deployment" ? 1 : 0}" We can't use conditional output, and I doesn't want to split the module in two
  metadata {
    name = "todo-backend"
    namespace = "${kubernetes_namespace.todo_backend.metadata.0.name}"
  }
  spec {
    selector {
      app = "backend"
    }
    session_affinity = "None"
    port {
      port = 80
      target_port = 3333
    }
    type = "LoadBalancer"
  }
}
// Create Deployment

data "template_file" "k8s" {
  count = "${var.mode=="deployment" ? 1 : 0}"

  template = "${file("${path.module}/k8s-todo-backend.tpl")}"

  vars {
    google_datastore_namespace = "${kubernetes_namespace.todo_backend.metadata.0.name}"
    google_project             = "${var.google_project}"
    registry_host              = "${var.registry_host}"
    version                    = "${var.version}"
    environment                = "${var.environment}"

  
  }
}

resource "null_resource" "kubernetes_deployment" {
  depends_on = ["google_project_iam_member.datastore_user"]
  count = "${var.mode=="deployment" ? 1 : 0}"

  triggers {
    configuration = "${data.template_file.k8s.rendered}"
  }

  provisioner "local-exec" {
    command = <<EOC
gcloud --project ${var.google_project} container clusters get-credentials ${data.terraform_remote_state.gke.name}; 
kubectl --namespace ${kubernetes_namespace.todo_backend.metadata.0.name} apply --record=true -f -  <<EOF
${data.template_file.k8s.rendered}
EOF
kubectl --namespace ${kubernetes_namespace.todo_backend.metadata.0.name} rollout status deployment backend -w
EOC
  }

}

// Todo
// Enable appengine.googleapis.com interfaces