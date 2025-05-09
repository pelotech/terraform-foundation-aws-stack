# Changelog

## [1.3.1](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v1.3.0...v1.3.1) (2025-05-09)


### Bug Fixes

* add outputs to support out of band IRSA configuration and update docs ([7d310bc](https://github.com/pelotech/terraform-foundation-aws-stack/commit/7d310bc1bd6f9d1e58736ef8c9dd94ae55fb1777))

## [1.3.0](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v1.2.1...v1.3.0) (2025-05-03)


### Features

* add configuration of eks version and ability to use existing VPC for cluster ([#23](https://github.com/pelotech/terraform-foundation-aws-stack/issues/23)) ([5db66fc](https://github.com/pelotech/terraform-foundation-aws-stack/commit/5db66fcf142e63a2d57827174f515e2bf354458c))

## [1.2.1](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v1.2.0...v1.2.1) (2025-05-03)


### Bug Fixes

* **deps:** update terraform terraform-aws-modules/eks/aws to v20.36.0 ([#18](https://github.com/pelotech/terraform-foundation-aws-stack/issues/18)) ([d352417](https://github.com/pelotech/terraform-foundation-aws-stack/commit/d352417a4d519adfe1fcb81cce76b6036eaab936))
* **deps:** update terraform terraform-aws-modules/iam/aws to v5.55.0 ([#16](https://github.com/pelotech/terraform-foundation-aws-stack/issues/16)) ([5559554](https://github.com/pelotech/terraform-foundation-aws-stack/commit/5559554bd0eeed2f37f1d0d5de7e04eb09d30d24))
* **deps:** update terraform terraform-aws-modules/s3-bucket/aws to v4.7.0 ([#17](https://github.com/pelotech/terraform-foundation-aws-stack/issues/17)) ([76de152](https://github.com/pelotech/terraform-foundation-aws-stack/commit/76de1523fb8ac7fbc0fa9ef8569179a8fb6f4853))
* **deps:** update terraform terraform-aws-modules/s3-bucket/aws to v4.8.0 ([#22](https://github.com/pelotech/terraform-foundation-aws-stack/issues/22)) ([2e57c23](https://github.com/pelotech/terraform-foundation-aws-stack/commit/2e57c23e07e61c15993260190d5ad6e731803d3e))
* **deps:** update terraform terraform-aws-modules/vpc/aws to v5.21.0 ([#19](https://github.com/pelotech/terraform-foundation-aws-stack/issues/19)) ([7a9d782](https://github.com/pelotech/terraform-foundation-aws-stack/commit/7a9d782e7ef0bd524667ac102639c80d33c0af02))
* **deps:** update tflint plugin terraform-linters/tflint-ruleset-aws to v0.39.0 ([#21](https://github.com/pelotech/terraform-foundation-aws-stack/issues/21)) ([9233bb6](https://github.com/pelotech/terraform-foundation-aws-stack/commit/9233bb6e3a457be0ff4cfcf66e172c7a2d340dbe))

## [1.2.0](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v1.1.0...v1.2.0) (2025-02-11)


### Features

* never version with updated eks/vpc deps. This may have breaking changes however it's unlikely ([16ccc32](https://github.com/pelotech/terraform-foundation-aws-stack/commit/16ccc3274f07208ba28b7ac933f262b7e1b35080))

## [1.1.0](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v1.0.2...v1.1.0) (2025-02-11)


### Features

* update to use release-please ([#8](https://github.com/pelotech/terraform-foundation-aws-stack/issues/8)) ([fd63b8e](https://github.com/pelotech/terraform-foundation-aws-stack/commit/fd63b8e85c6cb1dbc2889e4bc42ec379aea613d3))
