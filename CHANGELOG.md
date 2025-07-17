# Changelog

## [4.0.1](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v4.0.0...v4.0.1) (2025-07-17)


### Bug Fixes

* fix typo in variable validation namespace instead of namespaces ([#47](https://github.com/pelotech/terraform-foundation-aws-stack/issues/47)) ([bf0a156](https://github.com/pelotech/terraform-foundation-aws-stack/commit/bf0a156f92265ec9583e291b74411f9e4dddcdcb))

## [4.0.0](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v3.0.0...v4.0.0) (2025-07-17)


### ⚠ BREAKING CHANGES

* make extra entries more flexible and remove redundant ci arns for the entries ([#45](https://github.com/pelotech/terraform-foundation-aws-stack/issues/45))

### Features

* make extra entries more flexible and remove redundant ci arns for the entries ([#45](https://github.com/pelotech/terraform-foundation-aws-stack/issues/45)) ([decaf67](https://github.com/pelotech/terraform-foundation-aws-stack/commit/decaf679a4426906302a3abbbf5bcc4a260adf99))


### Bug Fixes

* **deps:** update terraform terraform-aws-modules/eks/aws to v20.37.2 ([#44](https://github.com/pelotech/terraform-foundation-aws-stack/issues/44)) ([c113b70](https://github.com/pelotech/terraform-foundation-aws-stack/commit/c113b705195a7b2aa272c29e7d50f643946fefb9))
* **deps:** update terraform terraform-aws-modules/iam/aws to v5.59.0 ([#43](https://github.com/pelotech/terraform-foundation-aws-stack/issues/43)) ([54cb519](https://github.com/pelotech/terraform-foundation-aws-stack/commit/54cb519c9757e5f9bb813de6926cef9b500f3a1e))

## [3.0.0](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v2.0.0...v3.0.0) (2025-06-28)


### ⚠ BREAKING CHANGES

* upgrade to eks 1.33 as well as al2023 instead of al2 ([#41](https://github.com/pelotech/terraform-foundation-aws-stack/issues/41))

### Features

* upgrade to eks 1.33 as well as al2023 instead of al2 ([#41](https://github.com/pelotech/terraform-foundation-aws-stack/issues/41)) ([27a097b](https://github.com/pelotech/terraform-foundation-aws-stack/commit/27a097b4d5947381dbb2431a2dd688a6e45c9a58))

## [2.0.0](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v1.4.0...v2.0.0) (2025-06-28)


### ⚠ BREAKING CHANGES

* upgrade the cluster to 1.32 as well as set the max pods to 110 ([#39](https://github.com/pelotech/terraform-foundation-aws-stack/issues/39))

### Features

* upgrade the cluster to 1.32 as well as set the max pods to 110 ([#39](https://github.com/pelotech/terraform-foundation-aws-stack/issues/39)) ([eaa8b38](https://github.com/pelotech/terraform-foundation-aws-stack/commit/eaa8b388bea929880ea67b1d4d6d46c566b15eab))

## [1.4.0](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v1.3.3...v1.4.0) (2025-06-22)


### Features

* add the ability to use fck-nat instead of the nat-gateway ([#36](https://github.com/pelotech/terraform-foundation-aws-stack/issues/36)) ([6821712](https://github.com/pelotech/terraform-foundation-aws-stack/commit/6821712c05aa9bc5939cadfd0f101375b0558d31))


### Bug Fixes

* **deps:** update terraform terraform-aws-modules/eks/aws to v20.37.1 ([#34](https://github.com/pelotech/terraform-foundation-aws-stack/issues/34)) ([47d8105](https://github.com/pelotech/terraform-foundation-aws-stack/commit/47d81059b7fbdb14931d5674ab1619d372663854))
* **deps:** update terraform terraform-aws-modules/s3-bucket/aws to v4.11.0 ([#33](https://github.com/pelotech/terraform-foundation-aws-stack/issues/33)) ([5e8c509](https://github.com/pelotech/terraform-foundation-aws-stack/commit/5e8c509eeeb17d5cf6e80047498b6336c01df38b))

## [1.3.3](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v1.3.2...v1.3.3) (2025-06-10)


### Bug Fixes

* **deps:** update terraform terraform-aws-modules/eks/aws to v20.37.0 ([#32](https://github.com/pelotech/terraform-foundation-aws-stack/issues/32)) ([255dc48](https://github.com/pelotech/terraform-foundation-aws-stack/commit/255dc4894212c4f2e9db6f7aeb5ec3af841b60ca))
* **deps:** update terraform terraform-aws-modules/iam/aws to v5.58.0 ([#31](https://github.com/pelotech/terraform-foundation-aws-stack/issues/31)) ([09503b5](https://github.com/pelotech/terraform-foundation-aws-stack/commit/09503b5a5218be1d4ef0f735d9d7a4bf3281a512))
* **deps:** update terraform terraform-aws-modules/s3-bucket/aws to v4.10.1 ([#29](https://github.com/pelotech/terraform-foundation-aws-stack/issues/29)) ([b090590](https://github.com/pelotech/terraform-foundation-aws-stack/commit/b0905909fd89aa08240adf0c579cc479419acdc1))
* **deps:** update tflint plugin terraform-linters/tflint-ruleset-aws to v0.40.0 ([#28](https://github.com/pelotech/terraform-foundation-aws-stack/issues/28)) ([ca09c8b](https://github.com/pelotech/terraform-foundation-aws-stack/commit/ca09c8bac64fd80c26b2c531fa7c37b283862070))

## [1.3.2](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v1.3.1...v1.3.2) (2025-05-21)


### Bug Fixes

* **deps:** update terraform terraform-aws-modules/s3-bucket/aws to v4.9.0 ([#26](https://github.com/pelotech/terraform-foundation-aws-stack/issues/26)) ([cfda7e5](https://github.com/pelotech/terraform-foundation-aws-stack/commit/cfda7e56350686ddff75bbbb5bfb83e18b0e22dc))

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
