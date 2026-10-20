# Apenas o bucket/configuracoes entram no Terraform; o JSON e enviado pelo script.
locals {
  firebase_bucket_name = "${var.project_name}-secrets-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  firebase_bucket_arn  = "arn:aws:s3:::${local.firebase_bucket_name}"
}

# O recurso aws_s3_bucket faz GetObjectLockConfiguration durante refresh,
# proibido por SCP no Learner Lab. O bucket comum usa somente APIs permitidas.
resource "terraform_data" "firebase_bucket" {
  input = {
    name    = local.firebase_bucket_name
    account = data.aws_caller_identity.current.account_id
    region  = var.aws_region
  }
  triggers_replace = [local.firebase_bucket_name]

  provisioner "local-exec" {
    command = "bash ../scripts/firebase-bucket.sh ensure"
    environment = {
      FIXA_BUCKET_NAME   = self.input.name
      FIXA_BUCKET_OWNER  = self.input.account
      FIXA_BUCKET_REGION = self.input.region
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash ../scripts/firebase-bucket.sh delete"
    environment = {
      FIXA_BUCKET_NAME   = self.input.name
      FIXA_BUCKET_OWNER  = self.input.account
      FIXA_BUCKET_REGION = self.input.region
    }
  }
}

resource "aws_s3_bucket_public_access_block" "firebase" {
  depends_on = [terraform_data.firebase_bucket]

  bucket                  = local.firebase_bucket_name
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "firebase" {
  depends_on = [terraform_data.firebase_bucket]

  bucket = local.firebase_bucket_name
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "firebase" {
  depends_on = [terraform_data.firebase_bucket]

  bucket = local.firebase_bucket_name
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "firebase" {
  bucket = local.firebase_bucket_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ReadFirebaseFromTaskRole"
        Effect    = "Allow"
        Principal = { AWS = data.aws_iam_role.lab.arn }
        Action    = "s3:GetObject"
        Resource  = "${local.firebase_bucket_arn}/firebase/*"
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.firebase_bucket_arn, "${local.firebase_bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
  depends_on = [terraform_data.firebase_bucket, aws_s3_bucket_public_access_block.firebase]
}

output "firebase_bucket" {
  depends_on = [terraform_data.firebase_bucket]

  value      = local.firebase_bucket_name
}
