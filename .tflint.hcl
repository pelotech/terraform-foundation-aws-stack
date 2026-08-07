# NOTE: .pre-commit-config.yaml invokes tflint with an explicit `--only=` allowlist, and every rule
# in that list belongs to the terraform ruleset. `--only` overrides both preset selection and any
# other enabled ruleset, so:
#   - the `preset` below is inert (the allowlist decides what runs, and two of the allowed rules —
#     terraform_standard_module_structure and terraform_naming_convention — are not even in
#     `recommended`);
#   - the aws ruleset was downloaded and initialized on every run without a single aws_* rule ever
#     executing, so it has been removed.
# To actually enable aws_* rules, re-add the plugin AND add the specific rule names to the
# `--only` list in .pre-commit-config.yaml.

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
