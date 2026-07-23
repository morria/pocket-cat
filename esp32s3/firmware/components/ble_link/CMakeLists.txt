idf_component_register(
    SRCS "ble_link.c"
    INCLUDE_DIRS "include"
    REQUIRES cat_bridge ctrl_proto bt
    PRIV_REQUIRES nvs_flash
)
