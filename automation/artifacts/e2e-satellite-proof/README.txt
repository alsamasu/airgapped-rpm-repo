================================================================================
E2E Satellite + Capsule Proof Run Evidence
================================================================================

This directory contains evidence from the end-to-end proof run of the
Red Hat Satellite + Capsule architecture for airgapped security patching.

Directory Structure:
--------------------
e2e-satellite-proof/
├── satellite/           # External Satellite server evidence
│   ├── cv-versions.txt  # Content View version listing
│   ├── sync-status.txt  # Repository sync status
│   ├── export-manifest.json  # Export bundle manifest
│   └── lifecycle-envs.txt    # Lifecycle environment listing
│
├── capsule/             # Internal Capsule server evidence
│   ├── import-report.txt     # Bundle import report
│   ├── content-listing.txt   # Served content listing
│   └── repolist.txt          # dnf repolist output
│
├── testers/             # Managed host evidence
│   ├── rhel8/
│   │   ├── pre-patch-packages.txt   # Package state before patching
│   │   ├── post-patch-packages.txt  # Package state after patching
│   │   ├── delta.txt                # Package changes (diff)
│   │   ├── uname-r.txt              # Running kernel version
│   │   ├── os-release.txt           # /etc/os-release contents
│   │   ├── updateinfo.txt           # Remaining security advisories
│   │   └── evidence-report.txt      # Comprehensive evidence report
│   │
│   └── rhel9/
│       ├── pre-patch-packages.txt
│       ├── post-patch-packages.txt
│       ├── delta.txt
│       ├── uname-r.txt
│       ├── os-release.txt
│       ├── updateinfo.txt
│       └── evidence-report.txt
│
└── README.txt           # This file

Evidence Collection Process:
----------------------------
1. SATELLITE: After sync/publish/export
   - hammer content-view version list > cv-versions.txt
   - hammer repository list > sync-status.txt
   - cat MANIFEST.json > export-manifest.json

2. CAPSULE: After import
   - Import script generates import-report.txt
   - dnf repolist > repolist.txt
   - ls -laR /var/lib/pulp/content > content-listing.txt

3. TESTERS: Before and after patching
   - Ansible playbook collects all evidence automatically
   - Evidence fetched to controller: artifacts/evidence/<hostname>/

Verification Criteria:
----------------------
[ ] cv_rhel8_security and cv_rhel9_security versions published
[ ] Lifecycle environments: Library -> test -> prod populated
[ ] Bundle exported with valid SHA256 checksum
[ ] Bundle imported successfully on Capsule
[ ] Managed hosts configured with capsule-*.repo files
[ ] Security updates applied (delta.txt shows changes)
[ ] Kernel updated if applicable (compare uname-r.txt)
[ ] No remaining security advisories (updateinfo.txt empty or INFO)
[ ] Post-reboot system running normally

Date: (timestamp to be filled during proof run)
Operator: (name to be filled during proof run)
================================================================================
