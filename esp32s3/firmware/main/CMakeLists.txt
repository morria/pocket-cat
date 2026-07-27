idf_component_register(
    SRCS "app_main.c" "led.c"
    INCLUDE_DIRS "."
    REQUIRES cat_bridge ctrl_proto usb_link ble_link spectrum
    PRIV_REQUIRES nvs_flash esp_timer driver esp_system
)
