include "StandardLibrary.dfy"
include "AwsCrypto.dfy"
include "Materials.dfy"
include "Cipher.dfy"
include "ByteBuf.dfy"

module Session {
  import opened StandardLibrary
  import opened Aws
  import opened Materials
  import EDK
  import Cipher
  import opened ByteBuffer
  import opened KeyringTraceModule

  // Encryption SDK mode
  datatype ProcessingMode = EncryptMode /* 0x9000 */ | DecryptMode /* 0x9001 */

  // Encryption SDK session
  datatype SessionState =
    /*** Common states ***/
    | Config          // Initial configuration. No data has been supplied
    | Error(Outcome)  // De/encryption failure. No data will be processed until reset
    | Done
    /*** Decrypt path ***/
    | ReadHeader
    | UnwrapKey
    | DecryptBody
    | CheckTrailer
    /*** Encrypt path ***/
    | GenKey
    | WriteHeader
    | EncryptBody
    | WriterTrailer


  class Session {
    const mode: ProcessingMode
    ghost var input_consumed: nat
    ghost var message_size: Option<nat>

    var state: SessionState
    const cmm: CMM

    /* Encrypt mode configuration */
    var precise_size: Option<nat> /* Exact size of message */
    var size_bound: nat   /* Maximum message size */
    var data_so_far: nat  /* Bytes processed thus far */

    /* The actual header, if parsed */
    var head_copy: array?<byte>
    var header_size: nat
    var header: Header
    const frame_size := 256 * 1024 /* Frame size, zero for unframed */

    /* List of (struct aws_cryptosdk_keyring_trace_record)s */
    var keyring_trace: seq<KeyringTrace>

    /* Estimate for the amount of input data needed to make progress. */
    var input_size_estimate: nat

    /* Estimate for the amount of output buffer needed to make progress. */
    var output_size_estimate: nat

    var frame_seqno: nat

    var alg_props: Cipher.AlgorithmProperties?

    /* Decrypted, derived (if applicable) content key */
    var content_key: Cipher.content_key?

    /* In-progress trailing signature context (if applicable) */
    var signctx: Cipher.SignCtx?

    /* Set to true after successful call to CMM to indicate availability
     * of keyring trace and--in the case of decryption--the encryption context.
     */
    var cmm_success: bool

    predicate Valid()
      reads this
    {
      (mode == EncryptMode || message_size == None) &&
      (state == Config ==>
        true) &&
      (state.Error? ==> state != Error(AWS_OP_SUCCESS))
    }

    constructor FromCMM(mode: ProcessingMode, cmm: CMM)
      modifies cmm
      ensures Valid()
      ensures this.mode == mode && this.input_consumed == 0 && this.message_size == None
      ensures cmm.refcount == old(cmm.refcount) + 1
    {
      this.mode := mode;
      this.cmm := cmm;
      this.header := new Header();
      new;
      Reset();
      this.state := Config;
      cmm.Retain();
    }

    method Reset()
      modifies this
      ensures state == Config
      ensures Valid()
      ensures input_consumed == 0 && message_size == None
    {
      this.input_consumed, this.message_size := 0, None;
      this.state := Config;
      this.precise_size := None;
      this.size_bound := UINT64_MAX;
      this.data_so_far := 0;
      this.cmm_success := false;
      this.head_copy := null;
      this.header_size := 0;
      this.header := new Header();
      this.keyring_trace := [];
      this.input_size_estimate := 1;
      this.output_size_estimate := 1;
      this.frame_seqno := 0;
      this.alg_props := null;
      this.signctx := null;
    }

    method SetMessageSize(message_size: nat) returns (r: Outcome)
      requires Valid() && mode == EncryptMode && this.message_size == None
      requires message_size <= size_bound
      modifies this
      ensures Valid() && input_consumed == old(input_consumed)
      ensures r == AWS_OP_SUCCESS ==> this.message_size == Some(message_size)
    {
      this.message_size := Some(message_size);
      if this.state == EncryptBody {
        priv_encrypt_compute_body_estimate();
      }
      return AWS_OP_SUCCESS;
    }

    /*****
    method ProcessEncrypt(outp: array<byte>, outlen: nat, inp: array<byte>, inlen: nat) returns (result: Outcome, out_bytes_written: nat, in_bytes_read: nat)
      requires Valid() && mode == EncryptMode
      requires state == Config
      requires outp != inp && inlen <= inp.Length && outlen <= outp.Length
      modifies this, outp
      ensures Valid() && message_size == old(message_size)
      ensures in_bytes_read <= inlen && out_bytes_written <= outlen
      ensures result != AWS_OP_SUCCESS ==>
                input_consumed == old(input_consumed) &&
                forall i :: 0 <= i < outlen ==> outp[i] == 0
      ensures result == AWS_OP_SUCCESS ==> state == Done
      ensures result == AWS_OP_SUCCESS ==>
                input_consumed == old(input_consumed) + in_bytes_read &&
                in_bytes_read == inlen
      ensures result == AWS_OP_SUCCESS && mode == EncryptMode ==>
                outp[..out_bytes_written] == Math.Encrypt(inp[..in_bytes_read])
      ensures result == AWS_OP_SUCCESS && mode == DecryptMode ==>
                outp[..out_bytes_written] == Math.Decrypt(inp[..in_bytes_read])
    {
      var output := ByteBuf(0, outp, 0, outlen);
      var input := ByteCursor(inlen, inp, 0);

      var prior_state, old_inp := state, input.ptr;

      var remaining_space := byte_buf_from_empty_array(output.enclosing_buffer, output.buffer_start_offset + output.len, output.capacity - output.len);

      label try: {
        result := priv_try_gen_key();
        if result != AWS_OP_SUCCESS { break try; }
        output := output.(len := output.len + remaining_space.len);
        result := priv_try_write_header(remaining_space);
        if result != AWS_OP_SUCCESS { break try; }
        output := output.(len := output.len + remaining_space.len);
        result := priv_try_encrypt_body(remaining_space, input);
        if result != AWS_OP_SUCCESS { break try; }
        output := output.(len := output.len + remaining_space.len);
        result := priv_write_trailer(remaining_space);
        if result != AWS_OP_SUCCESS { break try; }
        output := output.(len := output.len + remaining_space.len);
      }

      out_bytes_written, in_bytes_read := output.len, input.ptr;

      if result != AWS_OP_SUCCESS {
        state := Error(result);
        forall i | 0 <= i < outlen {
          outp[i] := 0;
        }
        out_bytes_written := 0;
      }
    }
    *****/

    /*****
    method Process(outp: array<byte>, outlen: nat, inp: array<byte>, inlen: nat) returns (result: Outcome, out_bytes_written: nat, in_bytes_read: nat)
      requires Valid()
      requires outp != inp && inlen <= inp.Length && outlen <= outp.Length
      modifies this, outp
      ensures Valid() && message_size == old(message_size)
      ensures in_bytes_read <= inlen && out_bytes_written <= outlen
      ensures result != AWS_OP_SUCCESS ==>
                input_consumed == old(input_consumed) &&
                forall i :: 0 <= i < outlen ==> outp[i] == 0
      ensures result == AWS_OP_SUCCESS ==>
                input_consumed == old(input_consumed) + in_bytes_read &&
                in_bytes_read == inlen
      ensures result == AWS_OP_SUCCESS && mode == EncryptMode ==>
                outp[..out_bytes_written] == Math.Encrypt(inp[..in_bytes_read])
      ensures result == AWS_OP_SUCCESS && mode == DecryptMode ==>
                outp[..out_bytes_written] == Math.Decrypt(inp[..in_bytes_read])
    {
      var output := ByteBuf(0, outp, 0, outlen);
      var input := ByteCursor(inlen, inp, 0);

      while true
        invariant Valid()
        invariant output.len <= outlen && input.ptr <= inlen
        invariant output.len <= output.capacity
        decreases outlen - output.len, inlen - input.ptr, if state == Config then 1 else 0
      {
        var prior_state, old_inp := state, input.ptr;

        var remaining_space := byte_buf_from_empty_array(output.enclosing_buffer, output.buffer_start_offset + output.len, output.capacity - output.len);

        match state {
          case Config =>
            state := if mode == EncryptMode then GenKey else ReadHeader;
            result := AWS_OP_SUCCESS;
          case Done =>
            result := AWS_OP_SUCCESS;
          case Error(err) =>
            result := err;
          /*** Decrypt path ***/
          case ReadHeader =>  // TODO
          case UnwrapKey =>  // TODO
          case DecryptBody =>  // TODO
          case CheckTrailer =>  // TODO
          /*** Encrypt path ***/
          case GenKey =>
            result := priv_try_gen_key();
          case WriteHeader =>
            result := priv_try_write_header(remaining_space);
          case EncryptBody =>
            result := priv_try_encrypt_body(remaining_space, input);
          case WriterTrailer =>
            result := priv_write_trailer(remaining_space);
        }
        var made_progress := remaining_space.len != 0 || input.ptr != old_inp || prior_state != state;

        output := output.(len := output.len + remaining_space.len);
        if result != AWS_OP_SUCCESS || !made_progress {
          break;
        }
      }

      out_bytes_written, in_bytes_read := output.len, input.ptr;

      if result != AWS_OP_SUCCESS {
        state := Error(result);
        forall i | 0 <= i < outlen {
          outp[i] := 0;
        }
        out_bytes_written := 0;
      }
    }
    *****/

    predicate method IsDone()
      requires Valid()
      reads this
      ensures mode == EncryptMode && Some(input_consumed) == message_size ==> IsDone()
      ensures mode == DecryptMode ==> IsDone()
    {
      true
    }

    method Destroy()
      requires Valid()
      modifies this, cmm
    {
      cmm.Release();
    }

    method priv_try_gen_key() returns (result: Outcome)
      modifies `alg_props, `signctx, `cmm_success, `keyring_trace, `content_key
      modifies header, header.message_id
    {
      var materials, data_key := null, null;
      label tryit: {
        // The default CMM will fill this in.
        var request := new EncryptionRequest(header.enc_context, if precise_size == None then UINT64_MAX else precise_size.get);

        result, materials := cmm.Generate(request);
        if result != AWS_OP_SUCCESS {
          result := AWS_OP_ERR;
          break tryit;
        }

        // Perform basic validation of the materials generated
        alg_props := Cipher.AlgProperties(materials.alg);
        if alg_props == null {
          result := AWS_CRYPTOSDK_ERR_CRYPTO_UNKNOWN;
          break tryit;
        }
        if materials.unencrypted_data_key.Length != alg_props.data_key_len {
          result := AWS_CRYPTOSDK_ERR_CRYPTO_UNKNOWN;
          break tryit;
        }
        if |materials.encrypted_data_keys| == 0 {
          result := AWS_CRYPTOSDK_ERR_CRYPTO_UNKNOWN;
          break tryit;
        }
        // We should have a signature context iff this is a signed alg suite
        if !(alg_props.signature_len == 0 <==> materials.signctx == null) {
          result := AWS_CRYPTOSDK_ERR_CRYPTO_UNKNOWN;
          break tryit;
        }

        // Move ownership of the signature context before we go any further.
        signctx, materials.signctx := materials.signctx, null;

        data_key := new byte[32];
        forall i | 0 <= i < materials.unencrypted_data_key.Length {
          data_key[i] := materials.unencrypted_data_key[i];
        }

        keyring_trace := materials.keyring_trace;
        cmm_success := true;

        // Generate message ID and derive the content key from the data key.
        result := Cipher.GenRandom(header.message_id);
        if result != AWS_OP_SUCCESS {
          result := AWS_CRYPTOSDK_ERR_CRYPTO_UNKNOWN;
          break tryit;
        }

        result, content_key := Cipher.DeriveKey(alg_props, data_key, header.message_id);
        if result != AWS_OP_SUCCESS {
          result := AWS_OP_ERR;
          break tryit;
        }

        result := build_header(materials);
        if result != AWS_OP_SUCCESS {
          result := AWS_OP_ERR;
          break tryit;
        }

        result := sign_header();
        if result != AWS_OP_SUCCESS {
          result := AWS_OP_ERR;
          break tryit;
        }

        result := AWS_OP_SUCCESS;
      }

      // Clean up
      if materials != null {
        forall i | 0 <= i < materials.unencrypted_data_key.Length {
          materials.unencrypted_data_key[i] := 0;
        }
        materials.Destroy();
      }
      if data_key != null {
        forall i | 0 <= i < data_key.Length {
          data_key[i] := 0;
        }
      }

      return result;
    }

    method build_header(materials: EncryptionMaterials) returns (r: Outcome)
      requires alg_props != null
      modifies header, materials
      ensures materials.unencrypted_data_key == old(materials.unencrypted_data_key)
    {
      header.alg_id := alg_props.alg_id;
      if UINT32_MAX < frame_size {
        return AWS_CRYPTOSDK_ERR_LIMIT_EXCEEDED;
      }
      header.frame_len := frame_size;

      // Swap the materials' EDK list for the header's.
      // When we clean up the materials structure we'll destroy the old EDK list.

      header.edk_list, materials.encrypted_data_keys := materials.encrypted_data_keys, header.edk_list;

      // The header should have been cleared earlier, so the materials structure should have
      // zero EDKs (otherwise we'd need to destroy the old EDKs as well).
      // TODO: check the property mentioned above, but not exactly like this:  assert |materials.encrypted_data_keys| == 0;

      header.iv := ByteBufInit_Full_AllZero(alg_props.iv_len);
      header.auth_tag := ByteBufInit_Full(alg_props.tag_len);

      return AWS_OP_SUCCESS;
    }

    // TODO
    method sign_header() returns (r: Outcome)

    method priv_encrypt_compute_body_estimate() {
      // TODO
    }
    method priv_try_write_header(remaining_space: ByteBuf) returns (result: Outcome) {
      // TODO
    }
    method priv_try_encrypt_body(remaining_space: ByteBuf, input: ByteCursor) returns (result: Outcome) {
      // TODO
    }
    method priv_write_trailer(remaining_space: ByteBuf) returns (result: Outcome) {
      // TODO
    }
  }

  type nat_4bytes = x | 0 <= x < 0x1_0000_0000

  class Header {
    var alg_id: AlgorithmID
    var frame_len: nat_4bytes
    var iv: ByteBuf
    var auth_tag: ByteBuf
    var message_id: array<byte>  // length 16
    var enc_context: EncryptionContext
    var edk_list: seq<EDK.EncryptedDataKey>

    // number of bytes of header except for IV and auth tag,
    // i.e., exactly the bytes that get authenticated
    var auth_len: nat

    constructor () {  // aws_cryptosdk_hdr_init
    }
  }
}
