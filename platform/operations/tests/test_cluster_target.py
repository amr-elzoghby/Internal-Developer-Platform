import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

DIRECTORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DIRECTORY))
spec = importlib.util.spec_from_file_location("in_cluster", DIRECTORY / "in-cluster.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
CONFIG = {"aws_region": "us-east-1", "aws_account_id": "851236938302", "cluster_name": "idp-prod"}


class ClusterTargetTest(unittest.TestCase):
    def test_wrong_account_stops_before_eks_lookup(self):
        with patch.object(module, "aws_json", return_value={"Account": "000000000001"}) as aws:
            with self.assertRaises(ValueError):
                module.kubeconfig(CONFIG)
            self.assertEqual(aws.call_count, 1)

    def test_snapshot_binds_arn_endpoint_certificate_and_region(self):
        arn = "arn:aws:eks:us-east-1:851236938302:cluster/idp-prod"
        cluster = {"arn": arn, "status": "ACTIVE", "endpoint": "https://verified.example", "certificateAuthority": {"data": "TEST_CA"}}
        with patch.object(module, "aws_json", side_effect=[{"Account": CONFIG["aws_account_id"]}, {"cluster": cluster}]):
            result = module.kubeconfig(CONFIG)
        self.assertEqual(result["current-context"], arn)
        self.assertEqual(result["clusters"][0]["cluster"]["certificate-authority-data"], "TEST_CA")
        self.assertNotIn("insecure-skip-tls-verify", result["clusters"][0]["cluster"])
        self.assertEqual(result["users"][0]["user"]["exec"]["args"][-2:], ["--region", "us-east-1"])


if __name__ == "__main__":
    unittest.main()
