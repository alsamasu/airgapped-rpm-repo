# Guide Validation Report

**Date:** 2025-12-30
**Status:** PASSED
**Guides Validated:** docs/deployment_guide.md docs/administration_guide.md

---

## Summary

| Metric | Count |
|--------|-------|
| Makefile targets verified | 15 |
| Static files verified | 6 |
| Scripts verified | 2 |
| PowerShell scripts verified | 1 |
| Errors | 0 |
| Warnings | 5 |

---

## Verified Makefile Targets

- ansible-onboard
- build-ovas
- e2e
- generate-ks-iso
- import
- manifests
- patch
- promote
- servers-deploy
- servers-destroy
- servers-report
- servers-wait
- spec-init
- validate-spec
- vsphere-discover

---

## Errors

None

---

## Warnings

- Runtime file not yet generated: automation/artifacts/spec.detected.yaml (created during execution)
- Runtime artifact not yet created: automation/artifacts/e2e (generated during execution)
- Runtime artifact not yet created: automation/artifacts/ovas (generated during execution)
- Runtime artifact not yet created: output/ks-isos (generated during execution)
- Runtime artifact not yet created: ansible/inventories/generated.yml (generated during execution)

---

## Validation Conclusion

All static artifacts verified. Runtime artifacts will be generated during execution.
