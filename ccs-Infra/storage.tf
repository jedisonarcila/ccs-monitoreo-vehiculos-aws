# =============================================================================
# S3 · tres buckets: estático (portal), video (cámaras), backups/auditoría
# -----------------------------------------------------------------------------
# Nombres con sufijo aleatorio (los nombres de bucket son globales en AWS).
# Los tres: acceso público bloqueado + cifrado en reposo (SSE-S3).
#   - static : origen de CloudFront (capa 6). Sin lifecycle.
#   - video  : Standard -> Standard-IA (30d) -> Glacier Instant Retrieval (365d).
#   - backups: -> Glacier Deep Archive (7d) -> expira a los ~7 años (retención
#              legal Colombia). Versionado activado.
# =============================================================================

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_static  = "${var.project}-static-${random_id.suffix.hex}"
  bucket_video   = "${var.project}-video-${random_id.suffix.hex}"
  bucket_backups = "${var.project}-backups-${random_id.suffix.hex}"
}

# ---------------------------- Buckets ----------------------------------------
resource "aws_s3_bucket" "static" {
  bucket = local.bucket_static
  tags   = { Name = local.bucket_static, Rol = "static" }
}

resource "aws_s3_bucket" "video" {
  bucket = local.bucket_video
  tags   = { Name = local.bucket_video, Rol = "video" }
}

resource "aws_s3_bucket" "backups" {
  bucket = local.bucket_backups
  tags   = { Name = local.bucket_backups, Rol = "backups" }
}

# ---------------------- Bloqueo de acceso público ----------------------------
resource "aws_s3_bucket_public_access_block" "static" {
  bucket                  = aws_s3_bucket.static.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "video" {
  bucket                  = aws_s3_bucket.video.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------- Cifrado en reposo (SSE-S3) ---------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "static" {
  bucket = aws_s3_bucket.static.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "video" {
  bucket = aws_s3_bucket.video.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# -------------------------- Lifecycle: video ---------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "video" {
  bucket = aws_s3_bucket.video.id

  rule {
    id     = "video-tiering"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 365
      storage_class = "GLACIER_IR" # Glacier Instant Retrieval
    }
  }
}

# ------------------------- Lifecycle: backups --------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "backups-archive"
    status = "Enabled"
    filter {}

    transition {
      days          = 7
      storage_class = "DEEP_ARCHIVE"
    }
    expiration {
      days = 2555 # ~7 años (retención legal Colombia)
    }
  }
}

# -------------------------- Versionado: backups ------------------------------
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}
