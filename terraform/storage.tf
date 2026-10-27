# Object Storage для картинок объявлений. Бакет создаётся ключом сервисного
# аккаунта storage, этим же ключом приложение пишет и читает объекты.

resource "random_string" "bucket_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "yandex_storage_bucket" "images" {
  bucket     = "${var.project}-images-${random_string.bucket_suffix.result}"
  access_key = yandex_iam_service_account_static_access_key.storage.access_key
  secret_key = yandex_iam_service_account_static_access_key.storage.secret_key

  # Картинки отдаются по presigned-ссылкам, публичного доступа нет
  anonymous_access_flags {
    read        = false
    list        = false
    config_read = false
  }

  versioning {
    enabled = false
  }

  depends_on = [yandex_resourcemanager_folder_iam_member.storage_editor]
}
