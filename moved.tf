# State address migrations.
#
# v9.0.0: load_balancer_controller_irsa_role and ebs_csi_driver_irsa_role gained `count` so they
# respect var.create like the other three IRSA roles already did. Adding count re-keys them from
# module.x to module.x[0]; these blocks carry the existing state across so the change is a no-op
# (no role replacement, ARNs unchanged) for consumers running the default create = true.
#
# Safe to delete once every consumer has applied a version >= 9.0.0.

moved {
  from = module.load_balancer_controller_irsa_role
  to   = module.load_balancer_controller_irsa_role[0]
}

moved {
  from = module.ebs_csi_driver_irsa_role
  to   = module.ebs_csi_driver_irsa_role[0]
}
