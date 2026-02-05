# Changelog

## [5.1.0](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v5.0.6...v5.1.0) (2026-02-05)


### Features

* upgrade to eks 1.35 ([#86](https://github.com/pelotech/terraform-foundation-aws-stack/issues/86)) ([82b69a7](https://github.com/pelotech/terraform-foundation-aws-stack/commit/82b69a7d45e1687f825b86bcd4114b1b6790b938))


### Chores

* **deps:** update actions/checkout digest to de0fac2 ([#85](https://github.com/pelotech/terraform-foundation-aws-stack/issues/85)) ([57dd537](https://github.com/pelotech/terraform-foundation-aws-stack/commit/57dd537dc1ed0155dc664a7d2b7ee61c6bb56a43))
* **deps:** update terraform terraform-aws-modules/eks/aws to v21.15.1 ([#83](https://github.com/pelotech/terraform-foundation-aws-stack/issues/83)) ([f2d113f](https://github.com/pelotech/terraform-foundation-aws-stack/commit/f2d113f70e1c311f919e0148de8eea9bdffa4a1d))
* **deps:** update terraform terraform-aws-modules/iam/aws to v6.4.0 ([#84](https://github.com/pelotech/terraform-foundation-aws-stack/issues/84)) ([2de189e](https://github.com/pelotech/terraform-foundation-aws-stack/commit/2de189ea15ec9d14021055cbfe693ef71ed475eb))

## [5.0.6](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v5.0.5...v5.0.6) (2026-01-18)


### Refactors

* update for latest iam modules - requires recreation of the policy due to new name format ([#81](https://github.com/pelotech/terraform-foundation-aws-stack/issues/81)) ([2d07f1c](https://github.com/pelotech/terraform-foundation-aws-stack/commit/2d07f1c7d29255b2c600574038ff59e106d0c965))

## [5.0.5](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v5.0.4...v5.0.5) (2026-01-18)


### Chores

* add renovate github pinning ([413c9d5](https://github.com/pelotech/terraform-foundation-aws-stack/commit/413c9d5d50a1fd6436d298b1c4b6f570f63cf788))
* **deps:** pin dependencies ([#80](https://github.com/pelotech/terraform-foundation-aws-stack/issues/80)) ([0b7de16](https://github.com/pelotech/terraform-foundation-aws-stack/commit/0b7de160b8c8965b725bb7317848d3bdb134d73f))
* **deps:** update actions/checkout action to v6 ([#77](https://github.com/pelotech/terraform-foundation-aws-stack/issues/77)) ([79a8f88](https://github.com/pelotech/terraform-foundation-aws-stack/commit/79a8f88abd12b8c4b69f92f17ef0dd28c5d23335))
* **deps:** update terraform terraform-aws-modules/eks/aws to v21.14.0 ([#75](https://github.com/pelotech/terraform-foundation-aws-stack/issues/75)) ([2815af8](https://github.com/pelotech/terraform-foundation-aws-stack/commit/2815af8f24fce4ff04ad195545bb3a870407a9ca))
* **deps:** update terraform terraform-aws-modules/s3-bucket/aws to v5.10.0 ([#78](https://github.com/pelotech/terraform-foundation-aws-stack/issues/78)) ([fb5cde8](https://github.com/pelotech/terraform-foundation-aws-stack/commit/fb5cde8cc51b005abd30b180045464548d3223f8))
* **deps:** update terraform terraform-aws-modules/vpc/aws to v6.6.0 ([#76](https://github.com/pelotech/terraform-foundation-aws-stack/issues/76)) ([d89342c](https://github.com/pelotech/terraform-foundation-aws-stack/commit/d89342c4a800a4ffa9f66c9382bd2ca8e673e305))
* **deps:** update tflint plugin terraform-linters/tflint-ruleset-aws to v0.44.0 ([#73](https://github.com/pelotech/terraform-foundation-aws-stack/issues/73)) ([67da665](https://github.com/pelotech/terraform-foundation-aws-stack/commit/67da66570d0730c4cd6cdb802b0ecdcf45efcafc))
* **deps:** update tflint plugin terraform-linters/tflint-ruleset-aws to v0.45.0 ([#79](https://github.com/pelotech/terraform-foundation-aws-stack/issues/79)) ([71f471c](https://github.com/pelotech/terraform-foundation-aws-stack/commit/71f471ce63d1f9dee17c9faf395ca285d8406085))

## [5.0.4](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v5.0.3...v5.0.4) (2025-10-27)


### Chores

* **deps:** update terraform terraform-aws-modules/eks/aws to v21.8.0 ([#71](https://github.com/pelotech/terraform-foundation-aws-stack/issues/71)) ([96526d1](https://github.com/pelotech/terraform-foundation-aws-stack/commit/96526d18d6135c619be468986e8cfcff278b8973))
* use inline policy to get around character limit ([f4df3de](https://github.com/pelotech/terraform-foundation-aws-stack/commit/f4df3deba2c78895d370423101eb719f6fce2083))

## [5.0.3](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v5.0.2...v5.0.3) (2025-10-22)


### Chores

* **deps:** update terraform terraform-aws-modules/eks/aws to v21.6.1 ([#67](https://github.com/pelotech/terraform-foundation-aws-stack/issues/67)) ([905b10b](https://github.com/pelotech/terraform-foundation-aws-stack/commit/905b10ba149f7065c773d1fa4a25d5a6bfafd3ea))
* **deps:** update terraform terraform-aws-modules/s3-bucket/aws to v5.8.2 ([#68](https://github.com/pelotech/terraform-foundation-aws-stack/issues/68)) ([71dca9f](https://github.com/pelotech/terraform-foundation-aws-stack/commit/71dca9f840f8cc634fa14a13f3f7e58e36965f0c))
* **deps:** update terraform terraform-aws-modules/vpc/aws to v6.5.0 ([#69](https://github.com/pelotech/terraform-foundation-aws-stack/issues/69)) ([75c5601](https://github.com/pelotech/terraform-foundation-aws-stack/commit/75c56010211ac4affb6d98e00375b0149ea40266))

## [5.0.2](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v5.0.1...v5.0.2) (2025-10-06)


### Bug Fixes

* upgrade to latest eks module, use forked karpenter module to reduce policy size ([85381cc](https://github.com/pelotech/terraform-foundation-aws-stack/commit/85381ccaa78f631ceb9d00531edf5525c418583f))


### Chores

* **deps:** update terraform terraform-aws-modules/vpc/aws to v6.4.0 ([#57](https://github.com/pelotech/terraform-foundation-aws-stack/issues/57)) ([bddf867](https://github.com/pelotech/terraform-foundation-aws-stack/commit/bddf867f899b67a79be0c0e6cea218cdab2b6dca))
* pre-commit fix ([8d91ff2](https://github.com/pelotech/terraform-foundation-aws-stack/commit/8d91ff287f03dbba09a89f4e17b3dcf8e668c1d8))

## [5.0.1](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v5.0.0...v5.0.1) (2025-09-27)


### Bug Fixes

* remove malformed resource and add option for hack to upgrade ([#62](https://github.com/pelotech/terraform-foundation-aws-stack/issues/62)) ([1294710](https://github.com/pelotech/terraform-foundation-aws-stack/commit/1294710722b1430d6df0605debada05c645f6ee9))


### Chores

* upgrade vpc, fck_nat, and s3 bucket modules ([#64](https://github.com/pelotech/terraform-foundation-aws-stack/issues/64)) ([1f9d387](https://github.com/pelotech/terraform-foundation-aws-stack/commit/1f9d387f4219fde16c2793462a408e7d4a134c5b))

## [5.0.0](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v4.0.2...v5.0.0) (2025-09-27)


### ⚠ BREAKING CHANGES

* upgrade eks module - has breaking change the to the interface ([#61](https://github.com/pelotech/terraform-foundation-aws-stack/issues/61))

### Features

* upgrade eks module - has breaking change the to the interface ([#61](https://github.com/pelotech/terraform-foundation-aws-stack/issues/61)) ([9aa7970](https://github.com/pelotech/terraform-foundation-aws-stack/commit/9aa7970ccda5cbd47d4d385eb6cc9a4c4f3fb15c))


### Chores

* **deps:** update tflint plugin terraform-linters/tflint-ruleset-aws to v0.43.0 ([#58](https://github.com/pelotech/terraform-foundation-aws-stack/issues/58)) ([d7ad2d3](https://github.com/pelotech/terraform-foundation-aws-stack/commit/d7ad2d31968caeda9d67b7c238aa34c0aec05d1c))

## [4.0.2](https://github.com/pelotech/terraform-foundation-aws-stack/compare/v4.0.1...v4.0.2) (2025-09-06)


### Bug Fixes

* allow for created vpc to be output ([4c49fc9](https://github.com/pelotech/terraform-foundation-aws-stack/commit/4c49fc9c71ff10bde579428f59b4f24af0edcf70))
* **deps:** update actions/checkout action to v5 ([#53](https://github.com/pelotech/terraform-foundation-aws-stack/issues/53)) ([8f5f860](https://github.com/pelotech/terraform-foundation-aws-stack/commit/8f5f8609e9e7bc8049119317594eb8ce65d46a6c))
* **deps:** update terraform terraform-aws-modules/iam/aws to v5.60.0 ([#51](https://github.com/pelotech/terraform-foundation-aws-stack/issues/51)) ([e399954](https://github.com/pelotech/terraform-foundation-aws-stack/commit/e399954dbd15742997023237abfabcf613684481))
* **deps:** update tflint plugin terraform-linters/tflint-ruleset-aws to v0.42.0 ([#50](https://github.com/pelotech/terraform-foundation-aws-stack/issues/50)) ([89538e6](https://github.com/pelotech/terraform-foundation-aws-stack/commit/89538e658c6c400da97c3270482a5de9e5228417))


### Chores

* update release please to include more change log sections ([96422f9](https://github.com/pelotech/terraform-foundation-aws-stack/commit/96422f9730fbf4f273486383ae5d6a54403969b1))

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
