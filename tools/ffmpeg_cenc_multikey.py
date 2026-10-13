"""Add bounded KID selection to pinned FFmpeg 6.1 without changing public ABI.

This is a local LGPL modification, not an upstream FFmpeg release. Public
option names follow FFmpeg's documented MOV/DASH multikey interface. The
sample-key cache is invalidated on key changes; no missing-key fallback is
allowed when a map is supplied. Input must be exact official 6.1 source.
"""
import hashlib
from pathlib import Path


ORIGINAL = {
    'isom.h': '182d718cbd56f8d38f4f0f03b506b5c621e085ffee7664857aebc12161050ee3',
    'mov.c': 'b5f0792dbe49b851a5c88b91ab20872a50ebeccafd1d60406288b653a3b80cf6',
    'dashdec.c': 'ddc9e46a4f691123a23ad0a0f195aebb204c66b08a4dc62d75af13b9a7787b60',
}
MARKER = '/* CKBridge multikey v6: supplied keys, live timeline, URL bounds and fragment recovery. */\n'

KEY_SELECTION = r'''
static int ck_hex_key(const char *text, uint8_t out[16])
{
    int i, nibble, value;
    if (!text || strlen(text) != 32)
        return AVERROR(EINVAL);
    for (i = 0; i < 32; i++) {
        unsigned char ch = text[i];
        if (ch >= '0' && ch <= '9') value = ch - '0';
        else if (ch >= 'a' && ch <= 'f') value = ch - 'a' + 10;
        else if (ch >= 'A' && ch <= 'F') value = ch - 'A' + 10;
        else return AVERROR(EINVAL);
        nibble = i & 1;
        if (!nibble) out[i / 2] = value << 4;
        else out[i / 2] |= value;
    }
    return 0;
}

static int ck_select_sample_key(MOVContext *c, MOVStreamContext *sc,
                                const AVEncryptionInfo *sample)
{
    uint8_t key[16];
    if (c->decryption_keys) {
        char kid[33];
        const AVDictionaryEntry *entry;
        if (!sample || !sample->key_id || sample->key_id_size != 16)
            return AVERROR_INVALIDDATA;
        ff_data_to_hex(kid, sample->key_id, 16, 1);
        entry = av_dict_get(c->decryption_keys, kid, NULL, AV_DICT_MATCH_CASE);
        if (!entry || ck_hex_key(entry->value, key) < 0) {
            av_log(c->fc, AV_LOG_ERROR, "No valid supplied key for encrypted sample\n");
            return AVERROR_INVALIDDATA;
        }
    } else {
        if (!c->decryption_key || c->decryption_key_len != sizeof(key))
            return AVERROR(EINVAL);
        memcpy(key, c->decryption_key, sizeof(key));
    }
    if (!sc->cenc.active_key_valid || memcmp(sc->cenc.active_key, key, sizeof(key))) {
        av_aes_ctr_free(sc->cenc.aes_ctr);
        sc->cenc.aes_ctr = NULL;
        av_freep(&sc->cenc.aes_ctx);
        memcpy(sc->cenc.active_key, key, sizeof(key));
        sc->cenc.active_key_valid = 1;
    }
    return 0;
}

'''


def replace(text, before, after, count=1):
    if text.count(before) != count:
        raise RuntimeError('Pinned FFmpeg patch context changed')
    return text.replace(before, after)


def transform(name, text):
    if name == 'isom.h':
        text = replace(text, '        struct AVAES *aes_ctx;\n',
                       '        struct AVAES *aes_ctx;\n'
                       '        uint8_t active_key[16];\n'
                       '        int active_key_valid;\n')
        text = replace(text, '    int decryption_key_len;\n',
                       '    int decryption_key_len;\n    AVDictionary *decryption_keys;\n')
    elif name == 'mov.c':
        signature = 'static int cenc_scheme_decrypt('
        text = replace(text, signature, KEY_SELECTION + signature)
        text = replace(text, 'av_aes_ctr_init(sc->cenc.aes_ctr, c->decryption_key)',
                       'av_aes_ctr_init(sc->cenc.aes_ctr, sc->cenc.active_key)', count=2)
        text = replace(text, 'av_aes_init(sc->cenc.aes_ctx, c->decryption_key, 16 * 8, 1)',
                       'av_aes_init(sc->cenc.aes_ctx, sc->cenc.active_key, 16 * 8, 1)', count=2)
        signature = ('static int cenc_decrypt(MOVContext *c, MOVStreamContext *sc, '
                     'AVEncryptionInfo *sample, uint8_t *input, int size)\n{\n')
        text = replace(text, signature, signature +
                       '    int ret = ck_select_sample_key(c, sc, sample);\n'
                       '    if (ret < 0) return ret;\n')
        text = replace(text, '        if (mov->decryption_key) {\n',
                       '        if (mov->decryption_key || mov->decryption_keys) {\n')
        text = replace(text, '        av_encryption_info_free(sc->cenc.default_encrypted_sample);\n'
                       '        av_aes_ctr_free(sc->cenc.aes_ctr);\n',
                       '        av_encryption_info_free(sc->cenc.default_encrypted_sample);\n'
                       '        av_aes_ctr_free(sc->cenc.aes_ctr);\n'
                       '        av_freep(&sc->cenc.aes_ctx);\n')
        option = ('    { "decryption_key", "The media decryption key (hex)", OFFSET(decryption_key), '
                  'AV_OPT_TYPE_BINARY, .flags = AV_OPT_FLAG_DECODING_PARAM },\n')
        text = replace(text, option, option +
                       '    { "decryption_keys", "Supplied media keys by KID (hex)", '
                       'OFFSET(decryption_keys), AV_OPT_TYPE_DICT, .flags = AV_OPT_FLAG_DECODING_PARAM },\n')
    elif name == 'dashdec.c':
        # Official6.1 can allocate64bytes for a64-byte URL then copy65bytes.
        # Account for the terminator before aligning all URL scratch buffers.
        text = replace(text, '    tmp_max_url_size = aligned(tmp_max_url_size);\n',
                       '    tmp_max_url_size = aligned(tmp_max_url_size + 1);\n')
        text = replace(text, '    char *cenc_decryption_key;\n',
                       '    char *cenc_decryption_key;\n    char *cenc_decryption_keys;\n'
                       '    char *ck_video_representation;\n    int ck_live_delay;\n'
                       '    int ck_fragment_retry;\n')
        text = replace(text, '    AVIOContext *input;\n',
                       '    AVIOContext *input;\n'
                       '    AVIOInterruptCB ck_parent_interrupt;\n    int64_t ck_open_deadline;\n')
        signature = ('static int open_url(AVFormatContext *s, AVIOContext **pb, const char *url,\n'
                     '                    AVDictionary **opts, AVDictionary *opts2, int *is_http)\n')
        text = replace(text, signature,
                       'static int ck_open_url(AVFormatContext *s, AVIOContext **pb, const char *url,\n'
                       '                       AVDictionary **opts, AVDictionary *opts2, int *is_http,\n'
                       '                       const AVIOInterruptCB *interrupt)\n')
        text = replace(text, '    ret = avio_open2(pb, url, AVIO_FLAG_READ, c->interrupt_callback, &tmp);\n',
                       '    ret = avio_open2(pb, url, AVIO_FLAG_READ, interrupt, &tmp);\n')
        text = replace(text, 'static char *get_content_url(xmlNodePtr *baseurl_nodes,\n',
                       'static int open_url(AVFormatContext *s, AVIOContext **pb, const char *url,\n'
                       '                    AVDictionary **opts, AVDictionary *opts2, int *is_http)\n'
                       '{\n    DASHContext *c = s->priv_data;\n'
                       '    return ck_open_url(s, pb, url, opts, opts2, is_http, c->interrupt_callback);\n}\n\n'
                       'static char *get_content_url(xmlNodePtr *baseurl_nodes,\n')
        recovery = r'''
/* The callback's opaque storage belongs to the representation,not the stack.
 * Disable its open deadline before normal body reads but retain user cancel. */
static int ck_fragment_interrupt(void *opaque)
{
    struct representation *pls = opaque;
    return ff_check_interrupt(&pls->ck_parent_interrupt) ||
           (pls->ck_open_deadline && av_gettime_relative() >= pls->ck_open_deadline);
}

/* Retry only pre-body transport failures on the same declared HTTP GET.
 * An HTTP status,certificate/format/key error or partial body is not replayed. */
static int ck_open_fragment(DASHContext *c, struct representation *pls,
                            const char *url, AVDictionary **opts)
{
    const AVDictionaryEntry *method = av_dict_get(c->avio_opts, "method", NULL, 0);
    int eligible = c->ck_fragment_retry &&
                   (av_strstart(url, "http://", NULL) || av_strstart(url, "https://", NULL)) &&
                   (!method || !strcmp(method->value, "GET")) &&
                   !av_dict_get(c->avio_opts, "post_data", NULL, 0);
    int ret, retries = 0;
    int64_t deadline = 0;
    AVIOInterruptCB interrupt = { ck_fragment_interrupt, pls };
    pls->ck_parent_interrupt = *c->interrupt_callback;
    for (;;) {
        if (ff_check_interrupt(c->interrupt_callback))
            return AVERROR_EXIT;
        pls->ck_open_deadline = deadline;
        ret = ck_open_url(pls->parent, &pls->input, url, &c->avio_opts, *opts, NULL,
                          deadline ? &interrupt : c->interrupt_callback);
        pls->ck_open_deadline = 0;
        if (ret >= 0 || !eligible || retries >= 2 ||
            !(ret == AVERROR_EOF || ret == AVERROR(ECONNRESET) ||
              ret == AVERROR(ECONNREFUSED) || ret == AVERROR(EPIPE) || ret == AVERROR(ETIMEDOUT)))
            return ret;
        if (!deadline)
            deadline = av_gettime_relative() + 5 * AV_TIME_BASE;
        {
            int64_t wake = av_gettime_relative() + (retries ? 750000 : 250000);
            int64_t remaining;
            if (wake + 100000 >= deadline)
                return ret;
            ff_format_io_close(pls->parent, &pls->input);
            while (av_gettime_relative() < wake) {
                if (ff_check_interrupt(c->interrupt_callback))
                    return AVERROR_EXIT;
                av_usleep(20000);
            }
            remaining = deadline - av_gettime_relative();
            if (remaining <= 0)
                return ret;
            if (av_dict_set_int(opts, "rw_timeout", remaining, 0) < 0 ||
                av_dict_set_int(opts, "timeout", remaining, 0) < 0)
                return AVERROR(ENOMEM);
        }
        retries++;
    }
}

'''
        signature = 'static int open_input(DASHContext *c, struct representation *pls, struct fragment *seg)\n'
        text = replace(text, signature, recovery + signature)
        text = replace(text, '    ret = open_url(pls->parent, &pls->input, url, &c->avio_opts, opts, NULL);\n',
                       '    ret = ck_open_fragment(c, pls, url, &opts);\n')
        text = replace(text, '            av_log(v->parent, AV_LOG_WARNING, "Failed to open fragment of playlist\\n");\n',
                       '            if (c->ck_fragment_retry)\n'
                       '                goto end; /* Bounded route fails rather than skipping forever. */\n'
                       '            av_log(v->parent, AV_LOG_WARNING, "Failed to open fragment of playlist\\n");\n')
        old_delay = '            start_time_offset = get_segment_start_time_based_on_timeline(pls, 0xFFFFFFFF) - 60 * pls->fragment_timescale; // 60 seconds before end\n'
        text = replace(text, old_delay,
                       '            /* Opt-in near-live start avoids expired DVR-window fragments. */\n'
                       '            start_time_offset = get_segment_start_time_based_on_timeline(pls, 0xFFFFFFFF) -\n'
                       '                                (int64_t)(c->ck_live_delay ? c->ck_live_delay : 60) * pls->fragment_timescale;\n')
        for kind in ['video', 'audio']:
            before = (
                f'            int64_t currentTime = get_segment_start_time_based_on_timeline(cur_{kind}, cur_{kind}->cur_seq_no) / cur_{kind}->fragment_timescale;\n'
                '            // update segments\n'
                f'            ccur_{kind}->cur_seq_no = calc_next_seg_no_from_timelines(ccur_{kind}, currentTime * cur_{kind}->fragment_timescale - 1);\n'
                f'            if (ccur_{kind}->cur_seq_no >= 0) {{\n'
                f'                move_timelines(ccur_{kind}, cur_{kind}, c);\n'
                '            }\n')
            after = (
                '            if (c->ck_live_delay) {\n'
                f'                int64_t relative = cur_{kind}->cur_seq_no - cur_{kind}->first_seq_no;\n'
                f'                int64_t wanted = get_segment_start_time_based_on_timeline(cur_{kind}, relative);\n'
                f'                int64_t index = calc_next_seg_no_from_timelines(ccur_{kind}, wanted - 1);\n'
                '                if (index >= 0) {\n'
                f'                    ccur_{kind}->cur_seq_no = ccur_{kind}->first_seq_no + index;\n'
                f'                    move_timelines(ccur_{kind}, cur_{kind}, c);\n'
                '                }\n'
                '            } else {\n' + before + '            }\n')
            text = replace(text, before, after)
        before = (
            '        min_seq_no = calc_min_seg_no(pls->parent, pls);\n'
            '        max_seq_no = calc_max_seg_no(pls, c);\n\n'
            '        if (pls->timelines || pls->fragments) {\n'
            '            refresh_manifest(pls->parent);\n'
            '        }\n')
        after = (
            '        if (c->ck_live_delay && pls->timelines) {\n'
            '            int64_t deadline = av_gettime_relative() + 20 * AV_TIME_BASE;\n'
            '            for (;;) {\n'
            '                if (ff_check_interrupt(c->interrupt_callback) ||\n'
            '                    refresh_manifest(pls->parent) < 0)\n'
            '                    return NULL;\n'
            '                min_seq_no = calc_min_seg_no(pls->parent, pls);\n'
            '                max_seq_no = calc_max_seg_no(pls, c);\n'
            '                if (pls->cur_seq_no <= max_seq_no)\n'
            '                    break;\n'
            '                /* Wait at live edge;never skip into unpublished numbers. */\n'
            '                if (av_gettime_relative() >= deadline)\n'
            '                    return NULL;\n'
            '                av_usleep(250000);\n'
            '            }\n'
            '        } else {\n' + before + '        }\n')
        text = replace(text, before, after)
        before = 'get_segment_start_time_based_on_timeline(pls, pls->cur_seq_no));'
        text = replace(text, before,
                       'get_segment_start_time_based_on_timeline(pls, pls->cur_seq_no - (c->ck_live_delay ? pls->first_seq_no : 0)));')
        selection = r'''
/* Filter before component probing,including every live manifest refresh. */
static int ck_select_video_representation(AVFormatContext *s)
{
    DASHContext *c = s->priv_data;
    struct representation *selected = NULL;
    int i, matches = 0;
    if (!c->ck_video_representation)
        return 0;
    if (!*c->ck_video_representation || strlen(c->ck_video_representation) > 128)
        return AVERROR(EINVAL);
    for (i = 0; i < c->n_videos; i++) {
        if (c->videos[i]->id && !strcmp(c->videos[i]->id, c->ck_video_representation)) {
            selected = c->videos[i];
            matches++;
        }
    }
    if (matches != 1) {
        av_log(s, AV_LOG_ERROR, "Selected DASH video is missing or ambiguous\n");
        return AVERROR_STREAM_NOT_FOUND;
    }
    for (i = 0; i < c->n_videos; i++) {
        if (c->videos[i] != selected)
            free_representation(c->videos[i]);
    }
    c->videos[0] = selected;
    c->n_videos = 1;
    return 0;
}

'''
        signature = 'static int parse_manifest(AVFormatContext *s, const char *url, AVIOContext *in)\n'
        text = replace(text, signature, selection + signature)
        text = replace(text, 'cleanup:\n        /*free the document */\n',
                       '        ret = ck_select_video_representation(s);\n'
                       'cleanup:\n        /*free the document */\n')
        forward = ('    if (c->cenc_decryption_key)\n'
                   '        av_dict_set(&in_fmt_opts, "decryption_key", c->cenc_decryption_key, 0);\n')
        text = replace(text, forward, forward +
                       '    if (c->cenc_decryption_keys)\n'
                       '        av_dict_set(&in_fmt_opts, "decryption_keys", c->cenc_decryption_keys, 0);\n')
        option = ('    { "cenc_decryption_key", "Media decryption key (hex)", '
                  'OFFSET(cenc_decryption_key), AV_OPT_TYPE_STRING, {.str = NULL}, '
                  'INT_MIN, INT_MAX, .flags = FLAGS },\n')
        text = replace(text, option, option +
                       '    { "cenc_decryption_keys", "Supplied media keys by KID (hex)", '
                       'OFFSET(cenc_decryption_keys), AV_OPT_TYPE_STRING, {.str = NULL}, '
                       'INT_MIN, INT_MAX, .flags = FLAGS },\n'
                       '    { "ck_video_representation", "Open only the declared DASH video ID", '
                       'OFFSET(ck_video_representation), AV_OPT_TYPE_STRING, {.str = NULL}, '
                       'INT_MIN, INT_MAX, .flags = FLAGS },\n'
                       '    { "ck_live_delay", "Opt-in live timeline delay in seconds", '
                       'OFFSET(ck_live_delay), AV_OPT_TYPE_INT, {.i64 = 0}, 0, 60, .flags = FLAGS },\n'
                       '    { "ck_fragment_retry", "Opt-in bounded pre-body fragment transport recovery", '
                       'OFFSET(ck_fragment_retry), AV_OPT_TYPE_BOOL, {.i64 = 0}, 0, 1, .flags = FLAGS },\n')
    else:
        raise RuntimeError('Unexpected patch target')
    return MARKER + text


def apply(source):
    """Validate all targets before writing, and verify repeated applications."""
    changes = []
    for name, checksum in ORIGINAL.items():
        path = Path(source) / 'libavformat' / name
        data = path.read_bytes()
        text = data.decode('utf-8')
        if text.startswith(MARKER):
            stamp = path.with_name(name + '.ck-original')
            original = stamp.read_bytes()
            if hashlib.sha256(original).hexdigest() != checksum or data != transform(name, original.decode('utf-8')).encode('utf-8'):
                raise RuntimeError('Previously patched FFmpeg source changed')
            continue
        if hashlib.sha256(data).hexdigest() != checksum:
            raise RuntimeError('Expected exact official FFmpeg 6.1 source')
        changes.append((path, data, transform(name, text).encode('utf-8')))
    for path, original, modified in changes:
        path.with_name(path.name + '.ck-original').write_bytes(original)
        path.write_bytes(modified)


if __name__ == '__main__':
    import sys
    apply(Path(sys.argv[1]))
    print('PASS: bounded FFmpeg 6.1 supplied-key map modification applied')
