# Inputs:
* app_name (string, required)
* size (string, required; e.g., 50G)

# Policy/security vars (see defaults)
* Outputs: storage_provisioner_result map with:
    * iqn,
    * target_portal
    * lun
    * lv_path,
    * size
    * fs_type.
* Idempotent: re‑running reconciles LV size (grow only), backstore and mapping.
* Does not delete. Separate role/action for deprovision.
