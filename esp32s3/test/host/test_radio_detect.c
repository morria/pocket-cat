/* Host unit tests for radio_detect (docs/implementation.md §7.1): VID/PID/
 * class fixtures → expected profile, interface index, default line coding. */
#include "radio_detect.h"
#include "unity.h"

void setUp(void) {}
void tearDown(void) {}

static void test_ft891_cp2105(void)
{
    /* CP2105: two vendor-specific interfaces (ECI + SCI). */
    static const rd_iface_t ifs[] = {
        { .number = 0, .if_class = RD_CLASS_VENDOR },
        { .number = 1, .if_class = RD_CLASS_VENDOR },
    };
    rd_device_t dev = { RD_VID_SILABS, RD_PID_CP2105, ifs, 2 };
    rd_profile_t p = radio_detect(&dev);
    TEST_ASSERT_EQUAL_INT(CTRL_RADIO_FT891, p.radio);
    TEST_ASSERT_EQUAL_INT(RD_DRIVER_CP210X, p.driver);
    TEST_ASSERT_EQUAL_UINT8(RD_FT891_CAT_IFACE, p.cat_iface); /* Enhanced/ECI */
    TEST_ASSERT_EQUAL_UINT32(4800, p.default_baud); /* factory default */
}

static void test_cp2102_generic_profile_not_ft891(void)
{
    /* §2.2: a CP2102 breakout must NOT match the FT-891 profile. */
    static const rd_iface_t ifs[] = {
        { .number = 0, .if_class = RD_CLASS_VENDOR },
    };
    rd_device_t dev = { RD_VID_SILABS, RD_PID_CP2102, ifs, 1 };
    rd_profile_t p = radio_detect(&dev);
    TEST_ASSERT_EQUAL_INT(CTRL_RADIO_GENERIC_CP210X, p.radio);
    TEST_ASSERT_EQUAL_INT(RD_DRIVER_CP210X, p.driver);
    TEST_ASSERT_EQUAL_UINT8(0, p.cat_iface);
}

static void test_ftx1_composite_audio_plus_cp210x(void)
{
    /* Expected FTX-1 shape: UAC audio interfaces + CP210x serial, unknown
     * PID. Per-interface matching must skip the audio function (§5.2). */
    static const rd_iface_t ifs[] = {
        { .number = 0, .if_class = RD_CLASS_AUDIO, .if_subclass = 0x01 },
        { .number = 1, .if_class = RD_CLASS_AUDIO, .if_subclass = 0x02 },
        { .number = 2, .if_class = RD_CLASS_AUDIO, .if_subclass = 0x02 },
        { .number = 3, .if_class = RD_CLASS_VENDOR }, /* the UART */
    };
    rd_device_t dev = { RD_VID_SILABS, 0xEA71 /* not EA70 */, ifs, 4 };
    rd_profile_t p = radio_detect(&dev);
    TEST_ASSERT_EQUAL_INT(CTRL_RADIO_GENERIC_CP210X, p.radio);
    TEST_ASSERT_EQUAL_UINT8(3, p.cat_iface); /* skipped the audio ifaces */
}

static void test_qmx_composite_cdc_plus_audio(void)
{
    /* QMX: STM32 composite — audio + CDC-ACM. Class match, not VID/PID. */
    static const rd_iface_t ifs[] = {
        { .number = 0, .if_class = RD_CLASS_AUDIO, .if_subclass = 0x01 },
        { .number = 1, .if_class = RD_CLASS_AUDIO, .if_subclass = 0x02 },
        { .number = 2, .if_class = RD_CLASS_AUDIO, .if_subclass = 0x02 },
        { .number = 3, .if_class = RD_CLASS_CDC_COMM,
          .if_subclass = RD_SUBCLASS_ACM },
        { .number = 4, .if_class = RD_CLASS_CDC_DATA },
    };
    rd_device_t dev = { 0x0483, 0xA34C, ifs, 5 }; /* STMicro example IDs */
    rd_profile_t p = radio_detect(&dev);
    TEST_ASSERT_EQUAL_INT(CTRL_RADIO_QMX_CDC, p.radio);
    TEST_ASSERT_EQUAL_INT(RD_DRIVER_CDC_ACM, p.driver);
    TEST_ASSERT_EQUAL_UINT8(3, p.cat_iface); /* the ACM *comm* interface */
}

static void test_plain_cdc_acm_device(void)
{
    static const rd_iface_t ifs[] = {
        { .number = 0, .if_class = RD_CLASS_CDC_COMM,
          .if_subclass = RD_SUBCLASS_ACM },
        { .number = 1, .if_class = RD_CLASS_CDC_DATA },
    };
    rd_device_t dev = { 0x1234, 0x5678, ifs, 2 };
    rd_profile_t p = radio_detect(&dev);
    TEST_ASSERT_EQUAL_INT(CTRL_RADIO_QMX_CDC, p.radio);
    TEST_ASSERT_EQUAL_UINT8(0, p.cat_iface);
}

static void test_ftdi_fallback(void)
{
    static const rd_iface_t ifs[] = {
        { .number = 0, .if_class = RD_CLASS_VENDOR },
    };
    rd_device_t dev = { RD_VID_FTDI, 0x6001, ifs, 1 };
    rd_profile_t p = radio_detect(&dev);
    TEST_ASSERT_EQUAL_INT(CTRL_RADIO_GENERIC_FTDI, p.radio);
    TEST_ASSERT_EQUAL_INT(RD_DRIVER_FTDI, p.driver);
}

static void test_unsupported_device(void)
{
    /* A HID keyboard: must stay attached but report UNSUPPORTED (§5.2). */
    static const rd_iface_t ifs[] = {
        { .number = 0, .if_class = 0x03 /* HID */ },
    };
    rd_device_t dev = { 0x046D, 0xC31C, ifs, 1 };
    rd_profile_t p = radio_detect(&dev);
    TEST_ASSERT_EQUAL_INT(CTRL_RADIO_UNSUPPORTED, p.radio);
    TEST_ASSERT_EQUAL_INT(RD_DRIVER_NONE, p.driver);
}

static void test_no_interfaces(void)
{
    rd_device_t dev = { 0x0000, 0x0000, NULL, 0 };
    rd_profile_t p = radio_detect(&dev);
    TEST_ASSERT_EQUAL_INT(CTRL_RADIO_UNSUPPORTED, p.radio);
}

static void test_cp2105_match_beats_class_scan(void)
{
    /* Rule ordering (§5.2): the exact CP2105 match wins even if the device
     * somehow also carried a CDC interface. */
    static const rd_iface_t ifs[] = {
        { .number = 0, .if_class = RD_CLASS_VENDOR },
        { .number = 1, .if_class = RD_CLASS_CDC_COMM,
          .if_subclass = RD_SUBCLASS_ACM },
    };
    rd_device_t dev = { RD_VID_SILABS, RD_PID_CP2105, ifs, 2 };
    rd_profile_t p = radio_detect(&dev);
    TEST_ASSERT_EQUAL_INT(CTRL_RADIO_FT891, p.radio);
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_ft891_cp2105);
    RUN_TEST(test_cp2102_generic_profile_not_ft891);
    RUN_TEST(test_ftx1_composite_audio_plus_cp210x);
    RUN_TEST(test_qmx_composite_cdc_plus_audio);
    RUN_TEST(test_plain_cdc_acm_device);
    RUN_TEST(test_ftdi_fallback);
    RUN_TEST(test_unsupported_device);
    RUN_TEST(test_no_interfaces);
    RUN_TEST(test_cp2105_match_beats_class_scan);
    return UNITY_END();
}
