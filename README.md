# OpenRestyはどれくらいお気軽なウェブアプリ環境なのか。

OpenResty は Nginx をダイナミック・リバースプロキシーサーバに仕立て上げたり、テンプレートエンジンを仕込んでバックエンドの JSON API サーバにリクエストしたレスポンスデータを元にレンダリングして返したり、と色々便利に使えるお気楽ウェブアプリ環境なのだけれど、画像処理系のCPUに負荷のかかりそうなものでもお気軽にいけるのかなとふと疑問に思ったの実験してみる。

OpenResty や LuaRocks のインストールは homebrew でさっくり入るし、windows はパソコン初心者並の知識しかないのではしょる事にして、とりあえずテーマを決める。

「nginx 画像処理」でググってみると「簡単！リアルタイム画像変換をNginxだけで行う方法 | cloudrop」ってのが一番上にあったり「S3をバックエンドにngx_small_lightで画像を動的に ...」なんてサイトがあったり、気軽に出来そうな感じだし良いかもってことでこれいってみよ。

Note: ちなみに、作るー＞文章を書くって流れだと確実に面倒に思って書かなくなってしまうので、書きながら作っていくことにする。


## OpenRestyでイメージフィルタ｜下準備

とりあえず以下のようなディレクトリ構成にする。

```
./img-server/
├── conf
│   ├── mime.types
│   └── nginx.conf
├── logs
│   ├── access.log
│   └── error.log
├── luahooks
│   ├── image.lua
│   └── init.lua
└── public
    └── images
        └── index.html


```

それから、その辺にころがってるファイルを元にしてテキトーに nginx.conf を以下のようにでっち上げる。

```nginx.conf

worker_processes    1;
events {
    worker_connections  1024;
    accept_mutex_delay  100ms;
}

http {
    sendfile            on;
    tcp_nopush          on;
    include             mime.types;
    default_type        text/html;
    index               index.html;
    
    #
    # log settings
    #
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  logs/access.log main;
    
    # 
    # lua global settings
    #
    lua_package_path        '$prefix/luahooks/?.lua;;';
    lua_check_client_abort  on;
    lua_code_cache          on;
    
    #
    # initialize script
    #
    init_by_lua_file        luahooks/init.lua;
    
    #
    # public
    #
    server {
        listen      1080;
        root        public/images;
        
        #
        # content handler
        #
        location / {
            content_by_lua_file         luahooks/image.lua;
        }
    }
}

```

これで初期化フェーズは `luahooks/image.lua` コンテントフェーズを `luahooks/image.lua` でフックすることにする。けど、後で都合が悪くなったら変えるかもしれない。それじゃ、まずは動作確認ってことで `luahooks/image.lua` の中身を以下のように書いて定番の「hello world」を表示してみる。

```image.lua
ngx.say('hello world');
```

それからプリフィックスを指定して `/path/to/command/nginx -p /path/to/img-server` で nginx を起動してブラウザで確認。
