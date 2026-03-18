terraform {
  backend "s3" {
    bucket         = "tfstate-ghr-d4b49c"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tfstate-ghr-d4b49c"
    profile        = "acg-main"
  }
}
