variable "project-id" {
  default = "gcp-2021-3-bookshelf-sydor"
}
variable "region" {
  default = "europe-central2"
}
variable "zone" {
  default = "europe-central2-a"
}
variable "vpc" {
  default = "vpc"
}
variable "vpc-subnet" {
  default = "vpc.subnet"
}
variable "ip-cidr-range" {
  default = "10.24.5.0/24"
}
variable "app-name" {
  default = "app-bookshelf"
}
variable "machine-type" {
  default = "e2-small"
}
variable "db_version" {
  default = "MYSQL_5_7"
}
variable "db_instance_tier" {
  default = "db-g1-small"
}