terraform {
  backend "s3" {
    bucket         = "your-tfstate-bucket" # replace before init
    key            = "healsync/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
