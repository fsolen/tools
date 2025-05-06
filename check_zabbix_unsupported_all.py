#!/usr/bin/env python3
# Script to check unsupported items and discovery rules in Zabbix 7 and export results to CSVs grouped by host and template
# https://github.com/fsolen/

import requests
import getpass
import csv
from collections import defaultdict

def sanitize_text(text):
    return text.replace('\n', ' ').replace('\r', ' ').strip()

def zabbix_api(method, params, auth=None):
    response = requests.post(
        f"{ZABBIX_URL}/api_jsonrpc.php",
        json={
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": 1,
            "auth": auth,
        },
        headers={"Content-Type": "application/json"}
    )
    response.raise_for_status()
    data = response.json()
    if "error" in data:
        print(f"\n Zabbix API Error ({method}): {data['error']['message']} - {data['error']['data']}")
        exit(1)
    return data["result"]

def prompt_credentials():
    global ZABBIX_URL
    while True:
        url = input(" Enter Zabbix URL (e.g. http://localhost/zabbix): ").strip().rstrip('/')
        if url:
            ZABBIX_URL = url
            break
        else:
            print(" Please enter a valid Zabbix URL.")
    user = input(" Username: ").strip()
    password = getpass.getpass(" Password: ").strip()
    return user, password

def check_templates(auth_token):
    results = defaultdict(list)
    templates = zabbix_api("template.get", {
        "output": ["templateid", "name"]
    }, auth_token)

    print(f"\n Checking {len(templates)} templates...\n")

    for tpl in templates:
        print(f" Template: {tpl['name']}")

        llds = zabbix_api("discoveryrule.get", {
            "output": ["name", "error"],
            "templateids": tpl["templateid"],
            "filter": {"state": "1"}
        }, auth_token)

        for rule in llds:
            results[tpl['name']].append(["Unsupported Discovery Rule", rule['name'], sanitize_text(rule['error'])])

    return results

def check_hosts(auth_token):
    results = defaultdict(list)
    hosts = zabbix_api("host.get", {
        "output": ["hostid", "name"],
        "filter": {"status": "0"}  # only monitored hosts
    }, auth_token)

    print(f"\n Checking {len(hosts)} monitored hosts...\n")

    for host in hosts:
        print(f" Host: {host['name']}")

        items = zabbix_api("item.get", {
            "output": ["name", "error"],
            "hostids": host["hostid"],
            "filter": {"state": "1"}
        }, auth_token)

        for item in items:
            results[host['name']].append(["Unsupported Item", item['name'], sanitize_text(item['error'])])

    return results

def export_grouped_to_csv(grouped_data, filename, group_label):
    with open(filename, mode='w', newline='', encoding='utf-8') as file:
        writer = csv.writer(file)
        writer.writerow([group_label, "Type", "Name", "Error"])
        for group, entries in grouped_data.items():
            for row in entries:
                writer.writerow([group] + row)
    print(f"Exported data to {filename}")

def main():
    user, password = prompt_credentials()

    print(" Authenticating to Zabbix...")
    auth_token = zabbix_api("user.login", {
        "username": user,
        "password": password
    })

    template_data = check_templates(auth_token)
    host_data = check_hosts(auth_token)

    export_grouped_to_csv(template_data, "zabbix_unsupported_discovery_rules_by_template.csv", "Template")
    export_grouped_to_csv(host_data, "zabbix_unsupported_items_by_host.csv", "Host")

    print("\n Full unsupported item and discovery rule check complete.")

if __name__ == "__main__":
    main()
