extends Node
## Synthetic projects and independent literal Minerva schema, through fresh children.
const StdioFixture := preload("res://test/test_stdio_transport.gd")
const DRIVER := """
import base64, copy, hashlib
payload = base64.b64decode('ewoJInZlcnNpb24iOiAiMS4wLjAiLAoJImlkX3ByZWZpeCI6ICJES1QiLAoJImlkX2Zvcm1hdCI6ICJ1dWlkNyIsCgkidHlwZXMiOiB7CgkJImJ1ZyI6IHsKCQkJImxhYmVsIjogIkJ1ZyIsCgkJCSJkZXNjcmlwdGlvbiI6ICJTb21ldGhpbmcgaXMgYnJva2VuLiIsCgkJCSJzdGF0ZXMiOiBbIm5ldyIsICJ0cmlhZ2VkIiwgImFjdGl2ZSIsICJyZXNvbHZlZCIsICJ2ZXJpZmllZCIsICJjbG9zZWQiXSwKCQkJImluaXRpYWxfc3RhdGUiOiAibmV3IiwKCQkJInRlcm1pbmFsX3N0YXRlcyI6IFsiY2xvc2VkIl0sCgkJCSJ0cmFuc2l0aW9ucyI6IHsKCQkJCSJuZXciOiBbInRyaWFnZWQiXSwKCQkJCSJ0cmlhZ2VkIjogWyJhY3RpdmUiLCAiY2xvc2VkIl0sCgkJCQkiYWN0aXZlIjogWyJyZXNvbHZlZCIsICJ0cmlhZ2VkIl0sCgkJCQkicmVzb2x2ZWQiOiBbInZlcmlmaWVkIiwgImFjdGl2ZSJdLAoJCQkJInZlcmlmaWVkIjogWyJjbG9zZWQiLCAiYWN0aXZlIl0sCgkJCQkiY2xvc2VkIjogW10KCQkJfSwKCQkJInRyYW5zaXRpb25fcnVsZXMiOiB7CgkJCQkicmVzb2x2ZWQiOiB7CgkJCQkJInJlcXVpcmVkX2ZpZWxkcyI6IFsicmVzb2x1dGlvbiJdCgkJCQl9CgkJCX0sCgkJCSJyZXF1aXJlZF9maWVsZHMiOiBbInRpdGxlIl0sCgkJCSJvcHRpb25hbF9maWVsZHMiOiBbImRlc2NyaXB0aW9uIiwgInNldmVyaXR5IiwgInByaW9yaXR5IiwgImVudmlyb25tZW50IiwgInJlc29sdXRpb24iLCAicmVwcm9fc3RlcHMiLCAiYXNzaWduZWRfdG8iLCAiZGlyZWN0ZWRfdG8iLCAidGFncyJdLAoJCQkicmVzb2x1dGlvbnMiOiBbImZpeGVkIiwgIndvbnRfZml4IiwgImJ5X2Rlc2lnbiIsICJkdXBsaWNhdGUiLCAibm90X3JlcHJvIl0KCQl9LAoJCSJkY3IiOiB7CgkJCSJsYWJlbCI6ICJEQ1IiLAoJCQkiZGVzY3JpcHRpb24iOiAiRGVzaWduIENoYW5nZSBSZXF1ZXN0LiIsCgkJCSJzdGF0ZXMiOiBbInByb3Bvc2VkIiwgImFwcHJvdmVkIiwgImRlc2lnbmluZyIsICJpbXBsZW1lbnRpbmciLCAicmV2aWV3aW5nIiwgInNoaXBwZWQiXSwKCQkJImluaXRpYWxfc3RhdGUiOiAicHJvcG9zZWQiLAoJCQkidGVybWluYWxfc3RhdGVzIjogWyJzaGlwcGVkIl0sCgkJCSJ0cmFuc2l0aW9ucyI6IHsKCQkJCSJwcm9wb3NlZCI6IFsiYXBwcm92ZWQiLCAic2hpcHBlZCJdLAoJCQkJImFwcHJvdmVkIjogWyJkZXNpZ25pbmciLCAicHJvcG9zZWQiXSwKCQkJCSJkZXNpZ25pbmciOiBbImltcGxlbWVudGluZyIsICJhcHByb3ZlZCJdLAoJCQkJImltcGxlbWVudGluZyI6IFsicmV2aWV3aW5nIiwgImRlc2lnbmluZyJdLAoJCQkJInJldmlld2luZyI6IFsic2hpcHBlZCIsICJpbXBsZW1lbnRpbmciXSwKCQkJCSJzaGlwcGVkIjogW10KCQkJfSwKCQkJInRyYW5zaXRpb25fcnVsZXMiOiB7fSwKCQkJInJlcXVpcmVkX2ZpZWxkcyI6IFsidGl0bGUiXSwKCQkJIm9wdGlvbmFsX2ZpZWxkcyI6IFsiZGVzY3JpcHRpb24iLCAic2V2ZXJpdHkiLCAicHJpb3JpdHkiLCAiYXNzaWduZWRfdG8iLCAiZGlyZWN0ZWRfdG8iLCAidGFncyJdCgkJfSwKCQkicmNhIjogewoJCQkibGFiZWwiOiAiUkNBIiwKCQkJImRlc2NyaXB0aW9uIjogIlJvb3QgQ2F1c2UgQW5hbHlzaXMuIiwKCQkJInN0YXRlcyI6IFsiZGV0ZWN0ZWQiLCAiaW52ZXN0aWdhdGluZyIsICJyb290X2NhdXNlZCIsICJyZW1lZGlhdGluZyIsICJ2ZXJpZmllZCIsICJjbG9zZWQiXSwKCQkJImluaXRpYWxfc3RhdGUiOiAiZGV0ZWN0ZWQiLAoJCQkidGVybWluYWxfc3RhdGVzIjogWyJjbG9zZWQiXSwKCQkJInRyYW5zaXRpb25zIjogewoJCQkJImRldGVjdGVkIjogWyJpbnZlc3RpZ2F0aW5nIl0sCgkJCQkiaW52ZXN0aWdhdGluZyI6IFsicm9vdF9jYXVzZWQiLCAiZGV0ZWN0ZWQiXSwKCQkJCSJyb290X2NhdXNlZCI6IFsicmVtZWRpYXRpbmciLCAiaW52ZXN0aWdhdGluZyJdLAoJCQkJInJlbWVkaWF0aW5nIjogWyJ2ZXJpZmllZCIsICJyb290X2NhdXNlZCJdLAoJCQkJInZlcmlmaWVkIjogWyJjbG9zZWQiLCAicmVtZWRpYXRpbmciXSwKCQkJCSJjbG9zZWQiOiBbXQoJCQl9LAoJCQkidHJhbnNpdGlvbl9ydWxlcyI6IHt9LAoJCQkicmVxdWlyZWRfZmllbGRzIjogWyJ0aXRsZSJdLAoJCQkib3B0aW9uYWxfZmllbGRzIjogWyJkZXNjcmlwdGlvbiIsICJzZXZlcml0eSIsICJwcmlvcml0eSIsICJhc3NpZ25lZF90byIsICJkaXJlY3RlZF90byIsICJ0YWdzIiwgIm9jY3VycmVkX2F0IiwgImRldGVjdGVkX2F0IiwgInJlcG9ydGVkX2F0IiwgIndoeV9jaGFpbiIsICJzaWduaWZpY2FudF9ldmVudHMiLCAiY29udHJpYnV0aW5nX2ZhY3RvcnMiXQoJCX0sCgkJImNob3JlIjogewoJCQkibGFiZWwiOiAiQ2hvcmUiLAoJCQkiZGVzY3JpcHRpb24iOiAiTWFpbnRlbmFuY2Ugd29yayB3aXRoIG5vIGJyb2tlbiBzdGF0ZS4iLAoJCQkic3RhdGVzIjogWyJvcGVuIiwgImluX3Byb2dyZXNzIiwgImRvbmUiXSwKCQkJImluaXRpYWxfc3RhdGUiOiAib3BlbiIsCgkJCSJ0ZXJtaW5hbF9zdGF0ZXMiOiBbImRvbmUiXSwKCQkJInRyYW5zaXRpb25zIjogewoJCQkJIm9wZW4iOiBbImluX3Byb2dyZXNzIl0sCgkJCQkiaW5fcHJvZ3Jlc3MiOiBbImRvbmUiLCAib3BlbiJdLAoJCQkJImRvbmUiOiBbXQoJCQl9LAoJCQkidHJhbnNpdGlvbl9ydWxlcyI6IHt9LAoJCQkicmVxdWlyZWRfZmllbGRzIjogWyJ0aXRsZSJdLAoJCQkib3B0aW9uYWxfZmllbGRzIjogWyJkZXNjcmlwdGlvbiIsICJwcmlvcml0eSIsICJhc3NpZ25lZF90byIsICJkaXJlY3RlZF90byIsICJ0YWdzIl0KCQl9LAoJCSJoaW50IjogewoJCQkibGFiZWwiOiAiSGludCIsCgkJCSJkZXNjcmlwdGlvbiI6ICJBbiBhY3Rpb25hYmxlIG1pY3JvLWZhY3QgZm9yIHRvb2wgb3Igd29ya2Zsb3cgcmVjYWxsLiIsCgkJCSJzdGF0ZXMiOiBbImRyYWZ0IiwgInZhbGlkYXRlZCIsICJwcm9tb3RlZCJdLAoJCQkiaW5pdGlhbF9zdGF0ZSI6ICJkcmFmdCIsCgkJCSJ0ZXJtaW5hbF9zdGF0ZXMiOiBbInByb21vdGVkIl0sCgkJCSJ0cmFuc2l0aW9ucyI6IHsKCQkJCSJkcmFmdCI6IFsidmFsaWRhdGVkIiwgInByb21vdGVkIl0sCgkJCQkidmFsaWRhdGVkIjogWyJwcm9tb3RlZCIsICJkcmFmdCJdLAoJCQkJInByb21vdGVkIjogW10KCQkJfSwKCQkJInRyYW5zaXRpb25fcnVsZXMiOiB7fSwKCQkJInJlcXVpcmVkX2ZpZWxkcyI6IFsidGl0bGUiLCAidmFsdWUiXSwKCQkJIm9wdGlvbmFsX2ZpZWxkcyI6IFsiZGVzY3JpcHRpb24iLCAiY29tcG9uZW50IiwgImtleSIsICJ0b3BpYyIsICJzdWJ0b3BpYyIsICJjb25maWRlbmNlIiwgInJldHJpZXZhbF9jb3VudCIsICJyZXNlYXJjaF9jb3N0IiwgInRhZ3MiLCAiZGlyZWN0ZWRfdG8iLCAicXVhbGl0eSIsICJsYXN0X3Jldmlld2VkIiwgInRhcmdldCIsICJzb3VyY2UiLCAicHJpc3RpbmVfaGFzaCIsICJwcmlzdGluZV9jb250ZW50IiwgImRlcHJlY2F0ZWQiXQoJCX0sCgkJImluc2lnaHQiOiB7CgkJCSJsYWJlbCI6ICJJbnNpZ2h0IiwKCQkJImRlc2NyaXB0aW9uIjogIkEgY29ycmVjdGlvbiB0byBhIG1lbnRhbCBtb2RlbC4iLAoJCQkic3RhdGVzIjogWyJkcmFmdCIsICJjb25maXJtZWQiXSwKCQkJImluaXRpYWxfc3RhdGUiOiAiZHJhZnQiLAoJCQkidGVybWluYWxfc3RhdGVzIjogWyJjb25maXJtZWQiXSwKCQkJInRyYW5zaXRpb25zIjogewoJCQkJImRyYWZ0IjogWyJjb25maXJtZWQiXSwKCQkJCSJjb25maXJtZWQiOiBbXQoJCQl9LAoJCQkidHJhbnNpdGlvbl9ydWxlcyI6IHt9LAoJCQkicmVxdWlyZWRfZmllbGRzIjogWyJ0aXRsZSIsICJhc3N1bWVkIiwgImNvcnJlY3RlZCJdLAoJCQkib3B0aW9uYWxfZmllbGRzIjogWyJkZXNjcmlwdGlvbiIsICJjb21wb25lbnQiLCAia2V5IiwgInRvcGljIiwgInN1YnRvcGljIiwgInN1cnByaXNlIiwgInN1cmZhY2VkX2Zyb20iLCAiY29uZmlkZW5jZSIsICJyZXRyaWV2YWxfY291bnQiLCAicmVzZWFyY2hfY29zdCIsICJ0YWdzIiwgImRpcmVjdGVkX3RvIiwgInF1YWxpdHkiLCAibGFzdF9yZXZpZXdlZCIsICJ0YXJnZXQiXQoJCX0sCgkJInF1ZXN0aW9uIjogewoJCQkibGFiZWwiOiAiUXVlc3Rpb24iLAoJCQkiZGVzY3JpcHRpb24iOiAiQmxvY2tpbmcga25vd2xlZGdlIHJlcXVlc3QuIiwKCQkJInN0YXRlcyI6IFsiYXNrZWQiLCAicmVzZWFyY2hpbmciLCAiZXNjYWxhdGVkIiwgImFuc3dlcmVkIl0sCgkJCSJpbml0aWFsX3N0YXRlIjogImFza2VkIiwKCQkJInRlcm1pbmFsX3N0YXRlcyI6IFsiYW5zd2VyZWQiXSwKCQkJInRyYW5zaXRpb25zIjogewoJCQkJImFza2VkIjogWyJyZXNlYXJjaGluZyIsICJlc2NhbGF0ZWQiLCAiYW5zd2VyZWQiXSwKCQkJCSJyZXNlYXJjaGluZyI6IFsiYW5zd2VyZWQiLCAiZXNjYWxhdGVkIiwgImFza2VkIl0sCgkJCQkiZXNjYWxhdGVkIjogWyJyZXNlYXJjaGluZyIsICJhbnN3ZXJlZCIsICJhc2tlZCJdLAoJCQkJImFuc3dlcmVkIjogW10KCQkJfSwKCQkJInRyYW5zaXRpb25fcnVsZXMiOiB7fSwKCQkJInJlcXVpcmVkX2ZpZWxkcyI6IFsidGl0bGUiXSwKCQkJIm9wdGlvbmFsX2ZpZWxkcyI6IFsiZGVzY3JpcHRpb24iLCAiZGlyZWN0ZWRfdG8iLCAiZmluZGluZ3MiLCAiYW5zd2VyIiwgInRhZ3MiLCAiYXNzaWduZWRfdG8iXQoJCX0sCgkJIndvcmtfaXRlbSI6IHsKCQkJImxhYmVsIjogIldvcmsgSXRlbSIsCgkJCSJkZXNjcmlwdGlvbiI6ICJHZW5lcmljIHRyYWNrYWJsZSB1bml0IG9mIHdvcmsuIiwKCQkJInN0YXRlcyI6IFsiYmFja2xvZyIsICJvcGVuIiwgImluX3Byb2dyZXNzIiwgImJsb2NrZWQiLCAiZG9uZSJdLAoJCQkiaW5pdGlhbF9zdGF0ZSI6ICJiYWNrbG9nIiwKCQkJInRlcm1pbmFsX3N0YXRlcyI6IFsiZG9uZSJdLAoJCQkidHJhbnNpdGlvbnMiOiB7CgkJCQkiYmFja2xvZyI6IFsib3BlbiJdLAoJCQkJIm9wZW4iOiBbImluX3Byb2dyZXNzIiwgImJhY2tsb2ciXSwKCQkJCSJpbl9wcm9ncmVzcyI6IFsiZG9uZSIsICJibG9ja2VkIiwgIm9wZW4iXSwKCQkJCSJibG9ja2VkIjogWyJpbl9wcm9ncmVzcyIsICJvcGVuIl0sCgkJCQkiZG9uZSI6IFtdCgkJCX0sCgkJCSJ0cmFuc2l0aW9uX3J1bGVzIjogewoJCQkJImJsb2NrZWQiOiB7CgkJCQkJInJlcXVpcmVkX2ZpZWxkcyI6IFsiYmxvY2tlZF9ieSJdCgkJCQl9CgkJCX0sCgkJCSJyZXF1aXJlZF9maWVsZHMiOiBbInRpdGxlIl0sCgkJCSJvcHRpb25hbF9maWVsZHMiOiBbImRlc2NyaXB0aW9uIiwgInNldmVyaXR5IiwgInByaW9yaXR5IiwgImFzc2lnbmVkX3RvIiwgImRpcmVjdGVkX3RvIiwgInRhZ3MiLCAiYmxvY2tlZF9ieSJdCgkJfSwKCQkic2VjcmV0IjogewoJCQkibGFiZWwiOiAiU2VjcmV0IiwKCQkJImRlc2NyaXB0aW9uIjogIkVuY3J5cHRlZCBjcmVkZW50aWFsIHdpdGggbG9jYXRpb24sIGlkZW50aXR5LCBhbmQgc2VjcmV0IHZhbHVlLiIsCgkJCSJzdGF0ZXMiOiBbImFjdGl2ZSIsICJyb3RhdGVkIiwgInJldm9rZWQiXSwKCQkJImluaXRpYWxfc3RhdGUiOiAiYWN0aXZlIiwKCQkJInRlcm1pbmFsX3N0YXRlcyI6IFsicmV2b2tlZCJdLAoJCQkidHJhbnNpdGlvbnMiOiB7CgkJCQkiYWN0aXZlIjogWyJyb3RhdGVkIiwgInJldm9rZWQiXSwKCQkJCSJyb3RhdGVkIjogWyJhY3RpdmUiLCAicmV2b2tlZCJdLAoJCQkJInJldm9rZWQiOiBbXQoJCQl9LAoJCQkidHJhbnNpdGlvbl9ydWxlcyI6IHt9LAoJCQkicmVxdWlyZWRfZmllbGRzIjogWyJ0aXRsZSJdLAoJCQkib3B0aW9uYWxfZmllbGRzIjogWyJkZXNjcmlwdGlvbiIsICJlbnZpcm9ubWVudCIsICJzdXJmYWNlZF9mcm9tIiwgImtleSIsICJ0YWdzIiwgImFzc2lnbmVkX3RvIl0KCQl9LAoJCSJlbmNyeXB0ZWRfbm90ZSI6IHsKCQkJImxhYmVsIjogIkVuY3J5cHRlZCBOb3RlIiwKCQkJImRlc2NyaXB0aW9uIjogIkVuY3J5cHRlZCBmcmVlLXRleHQgbm90ZSAoZGlhcnkgZW50cnksIEpTT04gYmxvYiwgZXRjLikuIiwKCQkJInN0YXRlcyI6IFsiZHJhZnQiLCAic2VhbGVkIl0sCgkJCSJpbml0aWFsX3N0YXRlIjogImRyYWZ0IiwKCQkJInRlcm1pbmFsX3N0YXRlcyI6IFsic2VhbGVkIl0sCgkJCSJ0cmFuc2l0aW9ucyI6IHsKCQkJCSJkcmFmdCI6IFsic2VhbGVkIl0sCgkJCQkic2VhbGVkIjogWyJkcmFmdCJdCgkJCX0sCgkJCSJ0cmFuc2l0aW9uX3J1bGVzIjoge30sCgkJCSJyZXF1aXJlZF9maWVsZHMiOiBbInRpdGxlIl0sCgkJCSJvcHRpb25hbF9maWVsZHMiOiBbImRlc2NyaXB0aW9uIiwgInRhZ3MiLCAiYXNzaWduZWRfdG8iXQoJCX0sCgkJInRlc3QiOiB7CgkJCSJsYWJlbCI6ICJUZXN0IiwKCQkJImRlc2NyaXB0aW9uIjogIkEgdGVzdCBjYXNlIHdpdGggc2V0dXAsIHN0ZXBzLCBhbmQgZXhwZWN0ZWQgcmVzdWx0LiIsCgkJCSJzdGF0ZXMiOiBbImRyYWZ0IiwgInJlYWR5IiwgInBhc3NpbmciLCAiZmFpbGluZyIsICJza2lwcGVkIiwgInJldGlyZWQiXSwKCQkJImluaXRpYWxfc3RhdGUiOiAiZHJhZnQiLAoJCQkidGVybWluYWxfc3RhdGVzIjogWyJyZXRpcmVkIl0sCgkJCSJ0cmFuc2l0aW9ucyI6IHsKCQkJCSJkcmFmdCI6IFsicmVhZHkiXSwKCQkJCSJyZWFkeSI6IFsicGFzc2luZyIsICJmYWlsaW5nIiwgInNraXBwZWQiXSwKCQkJCSJwYXNzaW5nIjogWyJmYWlsaW5nIiwgInJlYWR5IiwgInNraXBwZWQiLCAicmV0aXJlZCJdLAoJCQkJImZhaWxpbmciOiBbInBhc3NpbmciLCAicmVhZHkiLCAic2tpcHBlZCIsICJyZXRpcmVkIl0sCgkJCQkic2tpcHBlZCI6IFsicmVhZHkiLCAicmV0aXJlZCJdLAoJCQkJInJldGlyZWQiOiBbXQoJCQl9LAoJCQkidHJhbnNpdGlvbl9ydWxlcyI6IHt9LAoJCQkicmVxdWlyZWRfZmllbGRzIjogWyJ0aXRsZSJdLAoJCQkib3B0aW9uYWxfZmllbGRzIjogWyJkZXNjcmlwdGlvbiIsICJwcmlvcml0eSIsICJzZXZlcml0eSIsICJhc3NpZ25lZF90byIsICJkaXJlY3RlZF90byIsICJ0YWdzIiwgInRlc3Rfc2V0dXAiLCAidGVzdF9zdGVwcyIsICJleHBlY3RlZF9yZXN1bHQiLCAiZW52aXJvbm1lbnQiLCAiY29tcG9uZW50Il0KCQl9LAoJCSJkaXNjdXNzaW9uIjogewoJCQkibGFiZWwiOiAiRGlzY3Vzc2lvbiIsCgkJCSJkZXNjcmlwdGlvbiI6ICJBIHRocmVhZCBmb3IgYXN5bmMgZGlzY3Vzc2lvbjsgY29tbWVudHMgY2FycnkgdGhlIGNvbnRlbnQuIiwKCQkJInN0YXRlcyI6IFsiYWN0aXZlIiwgInJlc29sdmVkIl0sCgkJCSJpbml0aWFsX3N0YXRlIjogImFjdGl2ZSIsCgkJCSJ0ZXJtaW5hbF9zdGF0ZXMiOiBbXSwKCQkJInRyYW5zaXRpb25zIjogewoJCQkJImFjdGl2ZSI6IFsicmVzb2x2ZWQiXSwKCQkJCSJyZXNvbHZlZCI6IFsiYWN0aXZlIl0KCQkJfSwKCQkJInRyYW5zaXRpb25fcnVsZXMiOiB7fSwKCQkJInJlcXVpcmVkX2ZpZWxkcyI6IFsidGl0bGUiXSwKCQkJIm9wdGlvbmFsX2ZpZWxkcyI6IFsiZGVzY3JpcHRpb24iLCAidGFncyIsICJwcmlvcml0eSJdCgkJfSwKCQkic2tpbGwiOiB7CgkJCSJsYWJlbCI6ICJTa2lsbCIsCgkJCSJkZXNjcmlwdGlvbiI6ICJTZWxmLWNvbnRhaW5lZCBleGVjdXRhYmxlIHBpcGVsaW5lIGZvciBMTE0gdG9vbCB1c2FnZS4gU3RlcHMgZmllbGQgY29udGFpbnMgdGhlIGZ1bGwgcHJvY2VkdXJlLiIsCgkJCSJzdGF0ZXMiOiBbImRyYWZ0IiwgImFjdGl2ZSIsICJhcmNoaXZlZCJdLAoJCQkiaW5pdGlhbF9zdGF0ZSI6ICJkcmFmdCIsCgkJCSJ0ZXJtaW5hbF9zdGF0ZXMiOiBbXSwKCQkJInRyYW5zaXRpb25zIjogewoJCQkJImRyYWZ0IjogWyJhY3RpdmUiXSwKCQkJCSJhY3RpdmUiOiBbImFyY2hpdmVkIl0sCgkJCQkiYXJjaGl2ZWQiOiBbImFjdGl2ZSJdCgkJCX0sCgkJCSJ0cmFuc2l0aW9uX3J1bGVzIjoge30sCgkJCSJyZXF1aXJlZF9maWVsZHMiOiBbInRpdGxlIl0sCgkJCSJvcHRpb25hbF9maWVsZHMiOiBbImRlc2NyaXB0aW9uIiwgInN1bW1hcnkiLCAicHJvbXB0X3RleHQiLCAic3RlcHMiLCAicHJlY29uZGl0aW9ucyIsICJvdXRjb21lIiwgInRvb2xfZGVwcyIsICJvcHRpbWl6YXRpb24iLCAidGFyZ2V0IiwgImNvbXBvbmVudCIsICJ0b3BpYyIsICJzdWJ0b3BpYyIsICJjb25maWRlbmNlIiwgInRhZ3MiLCAiZGlyZWN0ZWRfdG8iLCAiYXNzaWduZWRfdG8iLCAicXVhbGl0eSIsICJsYXN0X3Jldmlld2VkIiwgInNvdXJjZSIsICJjdXN0b21pc2VkIiwgInByaXN0aW5lX2hhc2giLCAicHJpc3RpbmVfY29udGVudCIsICJ1bnNhdGlzZmllZF9kZXBzIiwgImRlcHJlY2F0ZWQiLCAia2V5Il0sCgkJCSJmaWVsZF9kZWZpbml0aW9ucyI6IHsKCQkJCSJ0b29sX2RlcHMiOiB7CgkJCQkJInR5cGUiOiAiYXJyYXkiLAoJCQkJCSJpdGVtcyI6IHsidHlwZSI6ICJzdHJpbmcifSwKCQkJCQkiZGVzY3JpcHRpb24iOiAiVG9vbCBuYW1lcyB0aGlzIHNraWxsIHJlcXVpcmVzIChhdXRvLWFjdGl2YXRlZCBvbiBza2lsbCBsb2FkKSIKCQkJCX0sCgkJCQkib3B0aW1pemF0aW9uIjogewoJCQkJCSJ0eXBlIjogIm9iamVjdCIsCgkJCQkJImRlc2NyaXB0aW9uIjogIlJ1bnRpbWUgb3B0aW1pemF0aW9uIHByb2ZpbGUgYXBwbGllZCB3aGVuIHNraWxsIGlzIGxvYWRlZC4gS2V5czogY29udGV4dF93aW5kb3cgKGludCksIHN1bW1hcnlfbW9kZSAoJ2RldGVybWluaXN0aWMnfCdsbG0nKSwgdG9vbF9pZGxlX3R1cm5zIChpbnQpLCB0b29sX2J1ZGdldCAoaW50KSIKCQkJCX0KCQkJfQoJCX0sCgkJInByb21wdCI6IHsKCQkJImxhYmVsIjogIlByb21wdCIsCgkJCSJkZXNjcmlwdGlvbiI6ICJBIHJldXNhYmxlIHByb21wdCB0ZW1wbGF0ZSBmb3IgTExNIGludGVyYWN0aW9ucy4iLAoJCQkic3RhdGVzIjogWyJkcmFmdCIsICJhY3RpdmUiLCAiYXJjaGl2ZWQiXSwKCQkJImluaXRpYWxfc3RhdGUiOiAiZHJhZnQiLAoJCQkidGVybWluYWxfc3RhdGVzIjogW10sCgkJCSJ0cmFuc2l0aW9ucyI6IHsKCQkJCSJkcmFmdCI6IFsiYWN0aXZlIl0sCgkJCQkiYWN0aXZlIjogWyJhcmNoaXZlZCJdLAoJCQkJImFyY2hpdmVkIjogWyJhY3RpdmUiXQoJCQl9LAoJCQkidHJhbnNpdGlvbl9ydWxlcyI6IHt9LAoJCQkicmVxdWlyZWRfZmllbGRzIjogWyJ0aXRsZSJdLAoJCQkib3B0aW9uYWxfZmllbGRzIjogWyJkZXNjcmlwdGlvbiIsICJwcm9tcHRfdGV4dCIsICJwYXJhbWV0ZXJzIiwgImNvbXBvbmVudCIsICJrZXkiLCAidG9waWMiLCAic3VidG9waWMiLCAiY29uZmlkZW5jZSIsICJ0YWdzIiwgImRpcmVjdGVkX3RvIiwgImFzc2lnbmVkX3RvIiwgInF1YWxpdHkiLCAibGFzdF9yZXZpZXdlZCIsICJ0YXJnZXQiXQoJCX0sCgkJImtiIjogewoJCQkibGFiZWwiOiAiS0IgQXJ0aWNsZSIsCgkJCSJkZXNjcmlwdGlvbiI6ICJBIGtub3dsZWRnZSBiYXNlIGFydGljbGUgb3IgcmVmZXJlbmNlIGRvY3VtZW50LiIsCgkJCSJzdGF0ZXMiOiBbImRyYWZ0IiwgImFjdGl2ZSIsICJhcmNoaXZlZCJdLAoJCQkiaW5pdGlhbF9zdGF0ZSI6ICJkcmFmdCIsCgkJCSJ0ZXJtaW5hbF9zdGF0ZXMiOiBbXSwKCQkJInRyYW5zaXRpb25zIjogewoJCQkJImRyYWZ0IjogWyJhY3RpdmUiXSwKCQkJCSJhY3RpdmUiOiBbImFyY2hpdmVkIl0sCgkJCQkiYXJjaGl2ZWQiOiBbImFjdGl2ZSJdCgkJCX0sCgkJCSJ0cmFuc2l0aW9uX3J1bGVzIjoge30sCgkJCSJyZXF1aXJlZF9maWVsZHMiOiBbInRpdGxlIl0sCgkJCSJvcHRpb25hbF9maWVsZHMiOiBbImRlc2NyaXB0aW9uIiwgImFydGljbGUiLCAic3VtbWFyeSIsICJrZXkiLCAiY29tcG9uZW50IiwgInRvcGljIiwgInN1YnRvcGljIiwgImNvbmZpZGVuY2UiLCAidGFncyIsICJkaXJlY3RlZF90byIsICJhc3NpZ25lZF90byIsICJxdWFsaXR5IiwgImxhc3RfcmV2aWV3ZWQiLCAic291cmNlIiwgInByaXN0aW5lX2hhc2giLCAicHJpc3RpbmVfY29udGVudCIsICJkZXByZWNhdGVkIl0KCQl9LAoJCSJwb2xpY3kiOiB7CgkJCSJsYWJlbCI6ICJQb2xpY3kiLAoJCQkiZGVzY3JpcHRpb24iOiAiV29ya2Zsb3cgcG9saWN5IGRlZmluaW5nIGdhdGVzLCB0b29sIHJlc3RyaWN0aW9ucywgYW5kIGVuZm9yY2VtZW50IHJ1bGVzLiBBbnlvbmUgY2FuIGluY3JlYXNlIGdhdGluZyBpbnRlbnNpdHk7IG9ubHkgaHVtYW5zIGNhbiBkZWNyZWFzZS4iLAoJCQkic3RhdGVzIjogWyJkcmFmdCIsICJwcm9wb3NlZCIsICJhY3RpdmUiLCAic3VzcGVuZGVkIiwgImFyY2hpdmVkIl0sCgkJCSJpbml0aWFsX3N0YXRlIjogImRyYWZ0IiwKCQkJInRlcm1pbmFsX3N0YXRlcyI6IFtdLAoJCQkidHJhbnNpdGlvbnMiOiB7CgkJCQkiZHJhZnQiOiBbInByb3Bvc2VkIl0sCgkJCQkicHJvcG9zZWQiOiBbImFjdGl2ZSIsICJkcmFmdCJdLAoJCQkJImFjdGl2ZSI6IFsic3VzcGVuZGVkIiwgImFyY2hpdmVkIl0sCgkJCQkic3VzcGVuZGVkIjogWyJhY3RpdmUiLCAiYXJjaGl2ZWQiXSwKCQkJCSJhcmNoaXZlZCI6IFsiYWN0aXZlIl0KCQkJfSwKCQkJInRyYW5zaXRpb25fcnVsZXMiOiB7fSwKCQkJInJlcXVpcmVkX2ZpZWxkcyI6IFsidGl0bGUiXSwKCQkJIm9wdGlvbmFsX2ZpZWxkcyI6IFsiZGVzY3JpcHRpb24iLCAiY29tcG9uZW50IiwgInRhZ3MiLCAiYXNzaWduZWRfdG8iLCAiZGlyZWN0ZWRfdG8iLCAic3RlcHMiLCAicHJlY29uZGl0aW9ucyIsICJvdXRjb21lIl0KCQl9Cgl9LAoJImNvbW1vbl9maWVsZHMiOiBbImlkIiwgInR5cGUiLCAic3RhdHVzIiwgInRpdGxlIiwgImRlc2NyaXB0aW9uIiwgImNyZWF0ZWRfYXQiLCAidXBkYXRlZF9hdCIsICJjcmVhdGVkX2J5IiwgImFzc2lnbmVkX3RvIiwgImRpcmVjdGVkX3RvIiwgInByaW9yaXR5IiwgInNldmVyaXR5IiwgInRhZ3MiLCAibGlua3MiLCAiZXZlbnRzIl0sCgkibGlua19yZWxhdGlvbnMiOiBbImNhdXNlZF9ieSIsICJibG9ja3MiLCAiZHVwbGljYXRlcyIsICJmb2xsb3dfdXAiLCAic3VyZmFjZWQiXSwKCSJwcmlvcml0eV92YWx1ZXMiOiBbMSwgMiwgMywgNF0sCgkic2V2ZXJpdHlfdmFsdWVzIjogWzEsIDIsIDMsIDRdCn0K')
assert hashlib.sha256(payload).hexdigest() == '1bf95da11825d2d0cb7e968f463c494b2348e0c7febf67e2fa7deea042219c48'
schema = json.loads(payload)
version = 'minerva-' + hashlib.sha256(payload).hexdigest()
a = 'a' * 64
env['DOCKET_PANEL_SECRET'] = a

def declare(p, value=schema, label=version, token=a, **extra):
    params = dict(panel_secret=token, schema=value, version=label)
    params.update(extra)
    return request(p, 'docket/panel/declare_schema', 91, params)

def call(p, name, arguments, failure=False):
    reply = request(p, 'tools/call', 92, dict(name=name, arguments=arguments))
    assert bool(reply['result'].get('isError')) == failure, reply
    return json.loads(reply['result']['content'][0]['text'])

def fields(p, project_name, slug):
    return call(p, 'docket_type_get', dict(project=project_name, type=slug))['definition']['fields']

try:
    if scenario == 'startup':
        for gui in (False, True):
            if gui: args.remove('--serve')
            untouched = base / ('gui.dct' if gui else 'headless.dct')
            untouched.write_bytes(b'untouched')
            for extra in (['--file', str(untouched)], ['--restore-session']):
                p = launch('startup-%s-%s' % (gui, len(extra)), ['--host-authority'] + extra)
                assert p.wait(timeout=10) == 2 and remaining_stdout(p) == b''
                assert untouched.read_bytes() == b'untouched'
            p = launch('empty-%s' % gui, ['--host-authority'])
            assert call(p, 'docket_project_list', {})['projects'] == []
            for mode in ('durable', 'session_file'):
                path = base / ('blocked-%s-%s.dct' % (gui, mode))
                refused = call(p, 'docket_project_add', dict(path=str(path), create=True, mode=mode), True)
                assert 'schema' in refused['error'].lower() and not list(base.glob(path.name + '*'))
            assert 'result' in declare(p)
            call(p, 'docket_project_add', dict(path=str(base / ('adopted-%s.dct' % gui)), create=True))
            for slug in ('hint', 'kb'):
                found = {f['key']: f['type'] for f in fields(p, 'adopted-%s' % gui, slug)}
                for key, kind in [('source','string'), ('pristine_hash','string'), ('pristine_content','object'), ('deprecated','boolean')]:
                    assert found[key] == kind, (slug, key, found)
            finish(p)
    elif scenario == 'schema':
        # An ordinary child provides an independently shipped v2 project and pinned item.
        old = base / 'existing.dct'
        p = launch('ordinary-seed', ['--file', str(old)])
        item = call(p, 'docket_create', dict(type='kb', title='stored', article='original'))
        original_type = call(p, 'docket_type_get', dict(type='kb'))
        original_item = call(p, 'docket_get', dict(id=item['id']))
        finish(p)
        before = old.read_bytes()
        legacy = base / 'legacy.dct'
        legacy.write_text(json.dumps(dict(_type='meta', version='1.0.0', counter=0, id_prefix='L', project='legacy')) + '\\n')
        p = launch('declared', ['--host-authority'])
        baseline = request(p, 'tools/list', 0)
        assert declare(p, token='b' * 64)['error']['code'] == -32001
        assert declare(p, panel_grant={})['error']['code'] == -32602
        invalid = [None, {}, dict(types=[]), dict(types={}), {'types': {'bad': 3}}]
        for key, value in [('states',[{}]), ('states',['draft','draft']), ('initial_state','absent'), ('transitions',{'draft':3}), ('transition_rules',{'draft':{'actor':'host'}}), ('field_definitions',{'title':3}), ('field_definitions',{'title':{'type':{}}}), ('field_definitions',{'title':{'type':'banana'}}), ('optional_fields',[3]), ('label',3)]:
            candidate = copy.deepcopy(schema)
            candidate['types']['kb'][key] = value
            invalid.append(candidate)
        for candidate in invalid:
            assert declare(p, value=candidate).get('error'), 'invalid schema adopted'
            assert request(p, 'tools/list', 0) == baseline, 'partial tool adoption'
        for label in ('', '   ', 3, None):
            assert declare(p, label=label).get('error')
        assert 'result' in declare(p)
        assert declare(p, value={'types': {'bad': 3}}).get('error')
        assert declare(p)['result']['idempotent'], 'invalid input replaced adopted schema'
        call(p, 'docket_project_add', dict(path=str(old)))
        assert old.read_bytes() == before, 'open rewrote persisted v2'
        assert call(p, 'docket_type_get', dict(project='existing', type='kb'))['current_revision'] == original_type['current_revision']
        assert call(p, 'docket_get', dict(project='existing', id=item['id'])) == original_item
        call(p, 'docket_project_add', dict(path=str(legacy)))
        new = base / 'fresh.dct'
        call(p, 'docket_project_add', dict(path=str(new), create=True))
        for project_name in ('legacy','fresh'):
            for slug in ('hint','kb'):
                found = {f['key']: f['type'] for f in fields(p, project_name, slug)}
                assert {key:found[key] for key in ('source','pristine_hash','pristine_content','deprecated')} == dict(source='string', pristine_hash='string', pristine_content='object', deprecated='boolean')
            for slug in ('policy','skill','prompt'):
                made = call(p, 'docket_create', dict(project=project_name, type=slug, title='owner '+slug, component='owner'))
                call(p, 'docket_update', dict(project=project_name, id=made['id'], component='updated'))
                got = call(p, 'docket_get', dict(project=project_name, id=made['id']))
                assert got['component'] == 'updated'
                queried = call(p, 'docket_query', dict(project=project_name, filter={'type':slug}))
                assert made['id'] in json.dumps(queried)
            for slug in ('secret','encrypted_note'):
                call(p, 'docket_create', dict(project=project_name, type=slug, title='forbidden'), True)
        unchanged = request(p, 'tools/list', 0)
        assert declare(p)['result']['idempotent']
        changed = copy.deepcopy(schema); changed['types']['kb']['description'] = 'conflict'
        assert declare(p, value=changed).get('error') and declare(p, label='different').get('error')
        assert request(p, 'tools/list', 0) == unchanged and old.read_bytes() == before
        assert fields(p, 'fresh', 'hint') == fields(p, 'legacy', 'hint')
        finish(p)
    else:
        raise AssertionError('unknown scenario')
    for log in base.glob('*.stderr'):
        assert b'SCRIPT ERROR' not in log.read_bytes(), 'child script error'
        assert a.encode() not in log.read_bytes(), 'authentication logged'
    print('HOST SCHEMA %s PASS' % scenario)
finally:
    for p, err in children:
        if p.poll() is None:
            p.kill(); p.wait(timeout=10)
        p.stop_io.set()
        for worker in p.io_threads: worker.join(timeout=1)
        p.stdin.close(); p.stdout.close(); err.close()
    root.cleanup()
    completed.set()
"""

func _run_scenario(scenario: String) -> Variant:
	var helpers := StdioFixture.DRIVER.get_slice("\ntry:\n    p = launch('scratch')", 0)
	# Hosted children intentionally start without the ordinary fixture's --file.
	helpers = helpers.replace(", '--file', str(base / (name + '.dct'))", "")
	var source := "import sys\nscenario = sys.argv.pop()\n" + helpers + DRIVER
	var output: Array = []
	var python := "python" if OS.get_name() == "Windows" else "python3"
	var code := OS.execute(python, PackedStringArray(["-c", source, OS.get_executable_path(), ProjectSettings.globalize_path("res://"), scenario]), output, true)
	var report := "\n".join(PackedStringArray(output)).replace("a".repeat(64), "[redacted]").replace("b".repeat(64), "[redacted]")
	print(report)
	return true if code == 0 and report.contains("HOST SCHEMA %s PASS" % scenario) else "Host schema %s failed (exit %d)" % [scenario,code]

func test_hosted_gui_and_headless_startup() -> Variant: return _run_scenario("startup")
func test_real_child_declaration_and_stored_semantics() -> Variant: return _run_scenario("schema")

var _saved_schema: Dictionary
var _saved_version: String
var _saved_opened: bool
var _saved_hosted: bool
const DIR := "user://test_host_schema"

func setup() -> void:
	_saved_schema = TypeRegistryBootstrap._declared_schema.duplicate(true)
	_saved_version = TypeRegistryBootstrap._declared_version
	_saved_opened = TypeRegistryBootstrap.projects_opened
	_saved_hosted = DocketRuntimeState.hosted
	TypeRegistryBootstrap._declared_schema = {}
	TypeRegistryBootstrap._declared_version = ""
	TypeRegistryBootstrap.projects_opened = false
	DocketRuntimeState.hosted = false
	DirAccess.make_dir_recursive_absolute(DIR)

func teardown() -> void:
	TypeRegistryBootstrap._declared_schema = _saved_schema
	TypeRegistryBootstrap._declared_version = _saved_version
	TypeRegistryBootstrap.projects_opened = _saved_opened
	DocketRuntimeState.hosted = _saved_hosted
	var directory := DirAccess.open(DIR)
	if directory != null:
		for name in directory.get_files(): directory.remove(name)
	DirAccess.remove_absolute(DIR)

func test_capability_gaps_preserve_pins_and_protected_trust() -> Variant:
	var path := DIR + "/stored.dct"
	var db := DocketDBJsonl.create_new_jsonl(path)
	if db == null: return "Cannot create synthetic v2"
	var registry := TypeRegistry.new(db)
	var made := registry.create_item({"type":"kb", "title":"pinned", "article":"original"})
	if made.has("error"): db.close(); return made.error
	var item: Dictionary = db.get_item(made.id)
	var before := FileAccess.get_file_as_string(path)
	var before_revision: String = registry.get_type("hint").current_revision
	var hint: Dictionary = TypeRegistryBootstrap.load_shipped_schema().types.hint.duplicate(true)
	hint.optional_fields.append("source")
	hint.field_definitions = {"value":{"type":"integer"}}
	hint.states.append("pending")
	hint.transitions.pending = []
	var schema := {"types":{"hint":hint, "widget":TypeRegistryBootstrap.load_shipped_schema().types.chore}}
	var declared := TypeRegistryBootstrap.declare_schema(schema, "test-gaps")
	if declared.has("error"): db.close(); return declared.error
	# Both stored shipped types and newly declared builtin names remain trusted.
	var error := registry.reload()
	var report := SchemaCapabilityGaps.compare(registry)
	var expected := ["field_kind:hint.value:string!=integer", "missing_field:hint.source", "missing_state:hint.pending", "missing_type:widget"]
	var preserved: bool = error.is_empty() and report.get("gaps") == expected and registry.get_type("hint").current_revision == before_revision and db.get_item(made.id) == item and FileAccess.get_file_as_string(path) == before
	for slug in ["secret", "encrypted_note"]:
		preserved = preserved and registry.create_item({"type":slug, "title":"forbidden"}).has("error")
	var custom: Dictionary = TypeRegistryBootstrap.records(schema).type_def_versions[1].definition
	custom.slug = "spoof"
	custom.protected_behavior = {"regular_creation_allowed":true, "blocking":{"enabled":true,"state":"open"}}
	var defined := registry.define_type("spoof", custom, "tester", "spoofed protected input", {"kind":"starter", "protected":true})
	preserved = preserved and not defined.has("error") and not registry.get_type("spoof").definition.protected and registry.get_type("spoof").definition.protected_behavior == {"regular_creation_allowed":true}
	db.close()
	var failed := SchemaCapabilityGaps.compare(registry).has("error")
	return true if preserved and failed else "Gap report, pins, protected trust or visible read failure changed"

func test_declaration_copy_replacement_and_gui_guards() -> Variant:
	DocketRuntimeState.hosted = true
	var state := AppState.new()
	state.load_schema()
	var path := DIR + "/refused.dct"
	state.load_dct(path)
	state.add_project(path)
	state.create_dct(path)
	state.create_and_add_project(path)
	if FileAccess.file_exists(path) or state.db != null: return "GUI touched a pre-schema project"
	var schema := TypeRegistryBootstrap.load_shipped_schema()
	if TypeRegistryBootstrap.declare_schema(schema, "first").has("error"): return "Valid first declaration refused"
	schema.types.kb.description = "next"
	if TypeRegistryBootstrap.effective_schema().types.kb.description == "next": return "Declaration retained caller-owned dictionary"
	if TypeRegistryBootstrap.declare_schema(schema, "next").has("error"): return "Valid before-open replacement refused"
	var adopted := TypeRegistryBootstrap.effective_schema()
	adopted.types.kb.description = "escaped"
	if TypeRegistryBootstrap.effective_schema().types.kb.description != "next": return "Effective schema leaked mutable state"
	TypeRegistryBootstrap.projects_opened = true
	if not TypeRegistryBootstrap.declare_schema(schema, "next").get("idempotent", false): return "Exact after-open retry refused"
	schema.types.kb.description = "conflict"
	if not TypeRegistryBootstrap.declare_schema(schema, "next").has("error"): return "Same-version changed body accepted"
	return true
