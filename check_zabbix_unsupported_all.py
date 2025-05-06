#!/usr/bin/env python3
# Script to check unsupported items and discovery rules in Zabbix 7 and export results to CSVs grouped by host and template
# https://github.com/fsolen/

import requests
import getpass
import csv
from collections import defaultdict

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
        print(f"\nZabbix API Error ({method}): {data['error']['message']} - {data['error']['data']}")
        exit(1)

    return data["result"]

def prompt_credentials():
    global ZABBIX_URL
    while True:
        url = input("Enter Zabbix URL (e.g. http://localhost/zabbix): ").strip().rstrip('/')
        if url:
            ZABBIX_URL = url
            break
        else:
            print("Please enter a valid Zabbix URL.")
    user = input("Username: ").strip()
    password = getpass.getpass("Password: ").strip()
    return user, password

def add_unsupported(group_key, title, entities, grouped_dict):
    if entities:
        for ent in entities:
            grouped_dict[group_key].append([title, ent['name'], ent['error']])

def check_templates(auth_token, lld_grouped):
    templates = zabbix_api("template.get", {
        "output": ["templateid", "name"]
    }, auth_token)

    print(f"\nChecking {len(templates)} templates...\n")

    for tpl in templates:
        print(f"Template: {tpl['name']}")

        llds = zabbix_api("discoveryrule.get", {
            "output": ["name", "error"],
            "templateids": tpl["templateid"],
            "filter": {"state": "1"}
        }, auth_token)

        add_unsupported(tpl["name"], "Unsupported Discovery Rule", llds, lld_grouped)

def check_hosts(auth_token, item_grouped):
    hosts = zabbix_api("host.get", {
        "output": ["hostid", "name"],
        "filter": {"status": "0"}
    }, auth_token)

    print(f"\nChecking {len(hosts)} monitored hosts...\n")

    for host in hosts:
        print(f"Host: {host['name']}")

        items = zabbix_api("item.get", {
            "output": ["name", "error"],
            "hostids": host["hostid"],
            "filter": {"state": "1"}
        }, auth_token)

        add_unsupported(host["name"], "Unsupported Item", items, item_grouped)

def export_grouped_to_csv(filename, grouped_dict, group_type):
    with open(filename, mode='w', newline='', encoding='utf-8') as file:
        writer = csv.writer(file)
        writer.writerow([group_type, "Type", "Name", "Error"])

        for group, entities in grouped_dict.items():
            for row in entities:
                writer.writerow([group] + row)

    print(f"Exported to {filename}")

def main():
    user, password = prompt_credentials()

    print("\nAuthenticating to Zabbix...")
    auth_token = zabbix_api("user.login", {
        "username": user,
        "password": password
    })

    item_grouped = defaultdict(list)  # host → items
    lld_grouped = defaultdict(list)   # template → discovery rules

    check_templates(auth_token, lld_grouped)
    check_hosts(auth_token, item_grouped)

    export_grouped_to_csv("zabbix_unsupported_items_by_host.csv", item_grouped, "Host")
    export_grouped_to_csv("zabbix_unsupported_discovery_rules_by_template.csv", lld_grouped, "Template")

    print("\nUnsupported item check complete.")

if __name__ == "__main__":
    main()
