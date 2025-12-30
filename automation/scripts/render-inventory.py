#!/usr/bin/env python3
"""
render-inventory.py
Generate Ansible inventory from spec.yaml configuration.

Usage:
    python3 render-inventory.py [--spec config/spec.yaml] [--output ansible/inventories/generated.yml]
"""

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Error: PyYAML not installed. Run: pip3 install pyyaml", file=sys.stderr)
    sys.exit(1)


def load_spec(spec_path: Path) -> dict:
    """Load and validate spec.yaml."""
    if not spec_path.exists():
        raise FileNotFoundError(f"Spec file not found: {spec_path}")
    
    with open(spec_path, 'r') as f:
        return yaml.safe_load(f)


def render_inventory(spec: dict) -> str:
    """Render Ansible inventory YAML from spec."""
    
    # Extract configuration
    vm_names = spec.get('vm_names', {})
    credentials = spec.get('credentials', {})
    ansible_cfg = spec.get('ansible', {})
    internal_repo = spec.get('https_internal_repo', {})
    syslog = spec.get('syslog_tls', {})
    internal_services = spec.get('internal_services', {})
    lifecycle = spec.get('lifecycle', {})
    
    # Build host inventory
    host_inventory = ansible_cfg.get('host_inventory', {})
    rhel9_hosts = host_inventory.get('rhel9_hosts', [])
    rhel8_hosts = host_inventory.get('rhel8_hosts', [])
    
    # Determine internal repo URL (placeholder until IPs known)
    internal_host = internal_repo.get('hostname') or vm_names.get('rpm_internal', 'rpm-internal')
    https_port = internal_repo.get('https_port', 8443)
    http_port = internal_repo.get('http_port', 8080)
    
    # Build inventory structure
    inventory = {
        'all': {
            'vars': {
                'ansible_user': ansible_cfg.get('ssh_username', 'admin'),
                'ansible_password': ansible_cfg.get('ssh_password', ''),
                'ansible_become': True,
                'ansible_become_password': ansible_cfg.get('become_password', ansible_cfg.get('ssh_password', '')),
                'ansible_ssh_common_args': '-o StrictHostKeyChecking=no',
                
                # Repository settings
                'internal_repo_host': internal_host,
                'internal_repo_https_port': https_port,
                'internal_repo_http_port': http_port,
                'internal_repo_url': f"https://{internal_host}:{https_port}",
                'repo_lifecycle_env': lifecycle.get('default_env', 'stable'),
                
                # Syslog TLS settings
                'syslog_tls_target_host': syslog.get('target_host', ''),
                'syslog_tls_target_port': syslog.get('target_port', 6514),
                'syslog_tls_ca_bundle_path': '/etc/pki/tls/certs/syslog-ca.crt',
                'onboard_configure_syslog': bool(syslog.get('target_host')),
                
                # Service user
                'service_user': internal_services.get('service_user', 'rpmops'),
                
                # Onboarding settings
                'onboard_disable_external_repos': True,
                'connectivity_retry_count': 3,
                'connectivity_retry_delay': 5,
                'preflight_check_disk_space_mb': 500,
            },
            'children': {
                'external_servers': {
                    'hosts': {
                        vm_names.get('rpm_external', 'rpm-external'): {
                            'ansible_host': '{{ external_server_ip }}',
                            'airgap_host_id': 'rpm-external-01',
                        }
                    }
                },
                'internal_servers': {
                    'hosts': {
                        vm_names.get('rpm_internal', 'rpm-internal'): {
                            'ansible_host': '{{ internal_server_ip }}',
                            'airgap_host_id': 'rpm-internal-01',
                        }
                    }
                },
                'rhel9_hosts': {
                    'vars': {
                        'ansible_python_interpreter': '/usr/bin/python3',
                        'repo_profile': 'rhel9',
                    },
                    'hosts': {}
                },
                'rhel8_hosts': {
                    'vars': {
                        'ansible_python_interpreter': '/usr/bin/python3.11',
                        'repo_profile': 'rhel8',
                    },
                    'hosts': {}
                },
                'managed_hosts': {
                    'children': {
                        'rhel9_hosts': None,
                        'rhel8_hosts': None,
                    }
                },
                'rpm_servers': {
                    'children': {
                        'external_servers': None,
                        'internal_servers': None,
                    }
                }
            }
        }
    }
    
    # Add RHEL 9 hosts
    for host in rhel9_hosts:
        hostname = host.get('hostname_or_ip', '')
        if hostname:
            inventory['all']['children']['rhel9_hosts']['hosts'][hostname] = {
                'ansible_host': hostname,
                'airgap_host_id': host.get('airgap_host_id', hostname.replace('.', '-')),
            }
    
    # Add RHEL 8 hosts
    for host in rhel8_hosts:
        hostname = host.get('hostname_or_ip', '')
        if hostname:
            inventory['all']['children']['rhel8_hosts']['hosts'][hostname] = {
                'ansible_host': hostname,
                'airgap_host_id': host.get('airgap_host_id', hostname.replace('.', '-')),
            }
    
    # Generate YAML with header comment
    header = """# Ansible Inventory - Generated from spec.yaml
# 
# This file is auto-generated. To modify:
#   1. Edit config/spec.yaml
#   2. Run: make render-inventory
#
# After deployment, update the IP addresses for rpm_external and rpm_internal
# with the actual DHCP-assigned IPs from: make servers-report
#
# Generated: {timestamp}

""".format(timestamp=__import__('datetime').datetime.now().isoformat())
    
    return header + yaml.dump(inventory, default_flow_style=False, sort_keys=False, allow_unicode=True)


def main():
    parser = argparse.ArgumentParser(description='Generate Ansible inventory from spec.yaml')
    parser.add_argument('--spec', '-s', default='config/spec.yaml',
                        help='Path to spec.yaml (default: config/spec.yaml)')
    parser.add_argument('--output', '-o', default='ansible/inventories/generated.yml',
                        help='Output inventory path (default: ansible/inventories/generated.yml)')
    parser.add_argument('--stdout', action='store_true',
                        help='Print to stdout instead of file')
    
    args = parser.parse_args()
    
    # Resolve paths
    script_dir = Path(__file__).parent
    repo_root = script_dir.parent.parent
    
    spec_path = Path(args.spec)
    if not spec_path.is_absolute():
        spec_path = repo_root / spec_path
    
    output_path = Path(args.output)
    if not output_path.is_absolute():
        output_path = repo_root / output_path
    
    try:
        spec = load_spec(spec_path)
        inventory_yaml = render_inventory(spec)
        
        if args.stdout:
            print(inventory_yaml)
        else:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            with open(output_path, 'w') as f:
                f.write(inventory_yaml)
            print(f"Inventory written to: {output_path}")
        
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"YAML Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
