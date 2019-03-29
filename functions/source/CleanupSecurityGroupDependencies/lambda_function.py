#  Copyright 2016 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
#  This file is licensed to you under the AWS Customer Agreement (the "License").
#  You may not use this file except in compliance with the License.
#  A copy of the License is located at http://aws.amazon.com/agreement/ .
#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied.
#  See the License for the specific language governing permissions and limitations under the License.

from __future__ import print_function
import boto3
import traceback
from botocore.vendored import requests
import json


SUCCESS = "SUCCESS"
FAILED = "FAILED"


def send(event, context, response_status, response_data, physical_resource_id):
    response_url = event['ResponseURL']

    print(response_url)

    response_body = dict()
    response_body['Status'] = response_status
    response_body['Reason'] = 'See the details in CloudWatch Log Stream: ' + context.log_stream_name
    response_body['PhysicalResourceId'] = physical_resource_id or context.log_stream_name
    response_body['StackId'] = event['StackId']
    response_body['RequestId'] = event['RequestId']
    response_body['LogicalResourceId'] = event['LogicalResourceId']
    response_body['Data'] = response_data

    json_response_body = json.dumps(response_body)

    print("Response body:\n" + json_response_body)

    headers = {
        'content-type': '',
        'content-length': str(len(json_response_body))
    }

    try:
        response = requests.put(response_url, data=json_response_body, headers=headers)
        print("Status code: " + response.reason)
    except Exception as e:
        print("send(..) failed executing requests.put(..): " + str(e))


def delete_dependencies(sg_id, c):
    for sg in c.describe_security_groups(Filters=[{'Name': 'ip-permission.group-id', 'Values': [sg_id]}])['SecurityGroups']:
        for p in sg['IpPermissions']:
            if 'UserIdGroupPairs' in p.keys():
                if sg_id in [x['GroupId'] for x in p['UserIdGroupPairs']]:
                    try:
                        c.revoke_security_group_ingress(GroupId=sg['GroupId'], IpPermissions=[p])
                    except Exception as e:
                        print("ERROR: %s %s" % (sg['GroupId'], str(e)))
    for sg in c.describe_security_groups(Filters=[{'Name': 'egress.ip-permission.group-id', 'Values': [sg_id]}])['SecurityGroups']:
        for p in sg['IpPermissionsEgress']:
            if 'UserIdGroupPairs' in p.keys():
                if sg_id in [x['GroupId'] for x in p['UserIdGroupPairs']]:
                    try:
                        c.revoke_security_group_egress(GroupId=sg['GroupId'], IpPermissions=[p])
                    except Exception as e:
                        print("ERROR: %s %s" % (sg['GroupId'], str(e)))
    for eni in c.describe_network_interfaces(Filters=[{'Name': 'group-id','Values': [sg_id]}])['NetworkInterfaces']:
        try:
            c.delete_network_interface(NetworkInterfaceId=eni['NetworkInterfaceId'])
        except Exception as e:
            print("ERROR: %s %s" % (eni['NetworkInterfaceId'], str(e)))


def lambda_handler(event, context):
    status = SUCCESS
    try:
        print(json.dumps(event))
        if event['RequestType'] == 'Delete':
            ec2 = boto3.client('ec2')
            for sg_id in event["ResourceProperties"]["SecurityGroups"]:
                delete_dependencies(sg_id, ec2)
    except Exception as e:
        status = FAILED
        print(e)
        traceback.print_exc()
    send(event, context, status, {}, '')
