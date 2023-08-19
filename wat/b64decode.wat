(module
  ;; fd_write(file_descriptor, *iovs, iovs_len, nwritten) -> i32: number of bytes written
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  ;; args_sizes_get(argc, argv_buf_size) -> i32: number of bytes written
  (import "wasi_snapshot_preview1" "args_sizes_get" (func $args_sizes_get (param i32 i32) (result i32)))
  ;; args_get(argv, argv_buf) -> i32: number of bytes written
  (import "wasi_snapshot_preview1" "args_get" (func $args_get (param i32 i32) (result i32)))

  (memory 1)
  (export "memory" (memory 0))

  ;; MEMORY LAYOUT
  ;; [0:3]  argc: size (u32) コマンドライン引数の数
  ;; [4:7]  argv_buf_size: size (32) コマンドライン引数のデータ長
  ;; [40:123] base64_chars: base64 デコードバイトテーブル
  ;; [124:1023] argv, argv_buf: コマンドライン引数のアドレス配列とデータ実体
  ;; [1024:] encoded_str_buf: エンコード後の文字列を格納するバッファ

  (data (i32.const 8) "usage: b64decode BASE64_STRING\00")
  (data (i32.const 40) "\40\40\40\3E\40\40\40\3F\34\35\36\37\38\39\3A\3B\3C\3D\40\40\40\40\40\40\40\00\01\02\03\04\05\06\07\08\09\0A\0B\0C\0D\0E\0F\10\11\12\13\14\15\16\17\18\19\40\40\40\40\40\40\1A\1B\1C\1D\1E\1F\20\21\22\23\24\25\26\27\28\29\2A\2B\2C\2D\2E\2F\30\31\32\33\40")
  (data (i32.const 1024) "                                                                                                                                ")

  (func $has_args (result i32)
    ;; コマンドライン引数の数 argc とデータ長 argv_buf_size をメモリに格納し、引数が与えられたかどうかを返す
    ;; result: コマンドライン引数ありなら 1、なければ 0

    (call $args_sizes_get
      (i32.const 0) ;; argc: size (u32) コマンドライン引数の数 -> [0:3] へ格納
      (i32.const 4)) ;; argv_buf_size: size (u32) コマンドライン引数のデータ長 -> [4:7] へ格納
    drop

    ;; argc > 1 ならばコマンドライン引数あり（i32.ge_u ではダメ、理由はコマンド名自身が argv[0] に入るため）
    (i32.gt_u (i32.load (i32.const 0)) (i32.const 1))
  )

  (func $get_first_arg (param $n_args i32) (param $argv_ptr i32) (result i32)
    ;; コマンドライン引数情報をメモリに格納し、1つ目のコマンドライン引数のデータ実体のアドレスを返す
    ;; $ n_args: コマンドライン引数の数 (given)、$has_args で格納した argc を指定する
    ;; $ argv_ptr: コマンドライン引数のアドレス配列を格納するアドレス (voluntary)

    ;; e.g. `wasmer b64decode.wasm foo bar ... baz` というコマンドで呼び出された時
    ;; | argv[0] | argv[1] | ... | argv[n] | argv_buf
    ;; | 4 bytes | 4 bytes | ... | 4 bytes | string
    ;; |   u32   |   u32   | ... |   u32   | "b64decode.wasm\0foo\0bar\0...\0baz"
    ;; ^                                   ^                  ^
    ;;(1)                                 (2)                (3)
    ;;
    ;; (1) $args_get 第1引数 ← このアドレスをどこにしたいか、$get_first_arg 呼び出し時に argv_ptr で渡す
    ;; (2) $args_get 第2引数 ← argv と衝突しないよう argv + (n_args * 4) に置くようにする
    ;; (3) この関数が返すアドレス (u32)
    (call $args_get
      (local.get $argv_ptr) ;; (1) → ここへコマンドライン引数のアドレス配列を格納
      (i32.add
        (local.get $argv_ptr)
        (i32.mul (local.get $n_args) (i32.const 4)) ;; argv_buf: コマンドライン引数のデータ実体を格納するアドレス
      ))
    drop

    ;; 1つ目のコマンドライン引数のデータ実体が格納されているアドレスを load = (3) -> スタックへ積む
    (i32.load (i32.add (local.get $argv_ptr) (i32.const 4)))
  )

  (func $str_len (param $str_ptr i32) (result i32)
    ;; 与えられた文字列の長さ（バイト長）を返す
    (local $n i32)
    (local.set $n (i32.const 0))

    (loop $next
      (if (i32.eqz (i32.load8_u (i32.add (local.get $str_ptr) (local.get $n))))
        (then
          (return (local.get $n)))
        (else nop)
      )
      (local.set $n (i32.add (local.get $n) (i32.const 1)))
      (br $next)
    )
    (unreachable)
  )

  (func $set_decoded_bytes (param $src_ptr i32) (param $src_len i32) (result i32)
    ;; base64 文字列をデコードし、デコード後のバイト列をメモリに格納する
    (local $n i32)
    (local $k i32)
    (local $decoded_quadbyte i32)
    (local $decoded_len i32)

    (local.set $n (i32.const 0))
    (local.set $k (i32.const 0))
    (local.set $decoded_len
      (i32.div_u (i32.mul (call $net_src_len (local.get $src_ptr) (local.get $src_len)) (i32.const 6)) (i32.const 8)))

    (loop $next_src_quartet (block $break
      (br_if $break (i32.gt_u (local.get $k) (local.get $decoded_len)))

      (local.set $decoded_quadbyte
        (i32.or
          (i32.or
            (i32.shl
              (i32.and 
                (i32.load8_u (i32.load8_u (i32.add (local.get $src_ptr) (local.get $n))))
                (i32.const 63))
              (i32.const 26)
            )
            (i32.shl
              (i32.and 
                (i32.load8_u (i32.load8_u (i32.add (local.get $src_ptr) (i32.add (local.get $n) (i32.const 1)))))
                (i32.const 63))
              (i32.const 20)
            )
          )
          (i32.or
            (i32.shl
              (i32.and 
                (i32.load8_u (i32.load8_u (i32.add (local.get $src_ptr) (i32.add (local.get $n) (i32.const 2)))))
                (i32.const 63))
              (i32.const 14)
            )
            (i32.shl
              (i32.and 
                (i32.load8_u (i32.load8_u (i32.add (local.get $src_ptr) (i32.add (local.get $n) (i32.const 3)))))
                (i32.const 63))
              (i32.const 8)
            )
          )
        )
      )

      (i32.store
        (i32.add (i32.const 1024) (local.get $k))
        (call $reorder_i32_byte (local.get $decoded_quadbyte))
      )

      ;; インクリメント／デクリメント
      (local.set $n (i32.add (local.get $n) (i32.const 4)))
      (local.set $k (i32.add (local.get $k) (i32.const 3)))
      (br $next_src_quartet)
    ))

    (local.get $decoded_len)
  )

  (func $net_src_len (param $src_ptr i32) (param $src_len i32) (result i32)
    ;; base64 文字列の末尾の `=` パディングを除いた長さ（バイト長）を返す
    (local $net_len i32)
    (local.set $net_len (local.get $src_len))
    (loop $next
      (if (i32.ne
        (i32.const 61) ;; '=' の文字コード
        (i32.load8_u (i32.add (local.get $src_ptr) (i32.sub (local.get $net_len) (i32.const 1)))))
        (then
          (return (local.get $net_len)))
        (else nop)
      )
      (local.set $net_len (i32.sub (local.get $net_len) (i32.const 1)))
      (br $next)
    )
    (unreachable)
  )

  (func $reorder_i32_byte (param $in i32) (result i32)
    ;; 与えられた 4 バイトの入力を、バイト順を逆にして返す
    ;; （※ WebAssembly のバイトオーダーはリトルエンディアンなため）
    ;; e.g. "\0A\0B\0C\0D" --(i32.load)--> 0x0D0C0B0A --($reorder_i32_byte)--> 0x0A0B0C0D
    (i32.or
      (i32.or
        (i32.shr_u (i32.and (local.get $in) (i32.const 0xff000000)) (i32.const 24))
        (i32.shr_u (i32.and (local.get $in) (i32.const 0xff0000)) (i32.const 8))
      )
      (i32.or
        (i32.shl (i32.and (local.get $in) (i32.const 0xff00)) (i32.const 8))
        (i32.shl (i32.and (local.get $in) (i32.const 0xff)) (i32.const 24))
      )
    )
  )

  (func $main (export "_start")
    (local $errno i32)
    (local $first_arg_ptr i32) ;; 1つ目のコマンドライン引数のアドレス
    (local $first_arg_len i32) ;; 1つ目のコマンドライン引数の長さ
    (local $output_ptr i32) ;; 出力文字列のアドレス
    (local $output_len i32) ;; 出力文字列長

    ;; デフォルトの出力文字列に base64_chars を設定
    (local.set $output_ptr (i32.const 8))
    (local.set $output_len (i32.const 31))

    (if (call $has_args)
      (then
        (local.set $first_arg_ptr (call $get_first_arg (i32.load (i32.const 0)) (i32.const 124)))
        (local.set $first_arg_len (call $str_len (local.get $first_arg_ptr)))

        (local.set $output_ptr (i32.const 1024))
        (local.set $output_len (call $set_decoded_bytes (local.get $first_arg_ptr) (local.get $first_arg_len)))
      )
      (else nop)
    )

    (i32.store (i32.const 0) (local.get $output_ptr))  ;; *iovs: io vector の先頭アドレス
    (i32.store (i32.const 4) (local.get $output_len))  ;; iovs_len: io vector のデータ実体のバイト長
    
    (local.set $errno
      (call $fd_write
        (i32.const 1) ;; file_descriptor: 1 = stdout
        (i32.const 0) ;; *iovs: io vector のアドレス
        (i32.const 1) ;; iovs_len: io vector の要素数
        (i32.const 0))) ;; nwritten: 出力文字列バイト数を格納するアドレス
  )
)