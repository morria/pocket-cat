idf_component_register(
    SRCS "usb_link.c"
    INCLUDE_DIRS "include"
    REQUIRES cat_bridge ctrl_proto usb
    PRIV_REQUIRES esp_timer
)
