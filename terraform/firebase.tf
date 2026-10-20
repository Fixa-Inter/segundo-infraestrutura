# Apenas o bucket/configuracoes entram no Terraform; o JSON e enviado pelo script.
resource "aws_s3_bucket" "firebase" {
  bucket        = "${var.project_name}-secrets-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "firebase" {
  bucket                  = aws_s3_bucket.firebase.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "firebase" {
  bucket = aws_s3_bucket.firebase.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "firebase" {
  bucket = aws_s3_bucket.firebase.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "firebase" {
  bucket = aws_s3_bucket.firebase.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ReadFirebaseFromTaskRole"
        Effect    = "Allow"
        Principal = { AWS = data.aws_iam_role.lab.arn }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.firebase.arn}/firebase/*"
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.firebase.arn, "${aws_s3_bucket.firebase.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.firebase]
}

output "firebase_bucket" {
  value = aws_s3_bucket.firebase.id
}
