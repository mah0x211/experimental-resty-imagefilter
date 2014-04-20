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

```nginx
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

```lua
ngx.say('hello world');
```

それからプリフィックスを指定して `/path/to/command/nginx -p /path/to/img-server` で nginx を起動してブラウザで表示確認。

問題なく確認できたので、次は写真を用意して `public/images/image.jpg` に置いてアクセスしてみる。が、もちろん表示されない。コンテントフェーズをフックしているからこれは当たり前なので、フックする箇所をアクセスフェーズに変更するように `nginx.conf` を書き換える。

```nginx
location / {
    access_by_lua_file  luahooks/image.lua;
}
```

そして `image.lua` もエラーログにアクセスしてきた URL を出力するように書き換える。

```lua
ngx.log( ngx.ERR, ngx.var.uri );
```

これで表示されるようになった。次はこの写真を変換する処理を作ってみる。

## OpenRestyでイメージフィルタ｜実装

そんなわけでリクエストをどう処理するかなんだけれど、クエリパラメータが多いと面倒なので Gravater - http://en.gravatar.com  っぽく `s=<size>` として正方形イメージに変換する。あともう一つ `q=<quality>` で画質も調整できるようにしておこう。ということで URL は `http://localhost:1080/image.jpg?s=100&q=50` という風になる。クエリパラメータが無い時はそのままの画像を返す。

処理の流れは以下のような感じ。

1. クエリパラメータをチェックする。
2. リクエストされた画像が存在するかの確認。
3. クエリパラメータに従って画像を変換する。
4. 変換した画像を返す。

どうやるか決まったので、これらの処理に必要なライブラリをインストールする。変換処理には `Imlib2` ライブラリを利用するので `brew install imlib2` でインストールした後に `luarocks install lua-imlib2` でモジュールをインストールする。それからリクエストされた画像の存在確認もする必要があるので、画像パスの存在確認用に `luaposix` モジュールも `luarocks install luaposix` としてインストールしておく。


### クエリーパラメータの処理と画像ファイルの存在確認

インストールが終わったら空っぽだった `init.lua` に以下のように書いてライブラリを読み込む。別に `image.lua` に書いてもいいんだけど、後々ファイルが増えたりした場合とか管理のわかりやすさの面から個人的に分けちゃうくせが付いてるだけなんだけどね。

```lua
require('posix');
require('imlib2');
```

クエリパラメータと画像の存在確認部分までの処理を `image.lua` に書いてみる。

```lua
local args = ngx.req.get_uri_args();
local size = tonumber( args.s );
local quality = tonumber( args.q );

if size or quality then
    local img = posix.realpath( ngx.var.document_root .. '/' .. ngx.var.uri );
    
    if img then
        ngx.log( ngx.ERR, img, ' size:', size, ' quality:', quality );
    end
end
```

これでブラウザから画像ファイルにアクセスすると、エラーログに画像ファイルの実パスとサイズと画質の指定値のログが吐き出されるのが確認できた。

### 画像ファイルの変換と保存

ここまできたら後は変換してブラウザに返すだけなんだけど `lua-imlib2` には画質を設定する項目がなかった。。。なんか面倒になって放置しようかと思ったけど、ふて寝して晩ご飯食べたらせっかくだしとやる気が復活。というわけで `luarocks remove lua-imlib2` で削除して、代わりにシンプルな `lua-thumbnailer` - https://github.com/mah0x211/lua-thumbnailer というモジュールを書いたので、これを `luarocks install https://raw.githubusercontent.com/mah0x211/lua-thumbnailer/master/thumbnailer-scm-1.rockspec` てな感じでインストールして `init.lua` も以下のように変更しとく。

```lua
thumbnailer = require('thumbnailer');
```

それから `image.lua` の処理を以下のようにクエリパラメータの調整やエラー処理も追加したりして、ごそっと書き換えます。

```lua
local args = ngx.req.get_uri_args();
local size = tonumber( args.s );
local quality = tonumber( args.q );

-- size value should be larger than 0
size = size and size > 0 and size or nil;
-- quality value should be 1 to 100
quality = quality and quality > 0 and quality <= 100 and quality or nil;

if size or quality then
    local img = posix.realpath( ngx.var.document_root .. '/' .. ngx.var.uri );
    
    if img then
        local filename, name, ext = ngx.var.uri:match( '(([^/.]+)%.(%w+))$' );
        local uri = ngx.var.uri:gsub( filename .. '$', 
                                      table.concat({name, size, quality}, '-' ) 
                                      .. '.' .. ext );
        
        -- set thumbnail-uri if it exists
        if posix.realpath( ngx.var.document_root .. '/' .. uri ) then
            ngx.req.set_uri( uri );
        else
            local err;
            img, err = thumbnailer.load( img );
            
            if img then
                
                if size then
                    -- resize( width, height, crop, horizontal_align, vertical_align )
                    img:resize( size, size, true, thumbnailer.ALIGN_CENTER, 
                                thumbnailer.ALIGN_MIDDLE );
                end
                
                if quality then
                    img:quality( quality );
                end
                
                err = img:save( ngx.var.document_root .. uri );
                if not err then
                    ngx.req.set_uri( uri );
                end
            end
            
            -- got error
            if err then
                ngx.log( ngx.ERR, err );
            end
        end
    end
end
```

これで画像のURL `http://localhost:1080/image.jpg?s=100&q=50` にアクセスするとサイズが100x100で画質が50のサムネイルが生成される。


## OpenRestyでイメージフィルタ｜まとめ

そんなこんなで、結局 C でモジュール書くはめになっちゃって休日を一日使ってしまってお気軽とはいかなかったけど、普通に nginx モジュールを書いたりするよりはお手軽ではないかと・・（苦）それと、今回作ったファイル一式は github に上げてるので触ってみたい人は気軽にどうぞ。

experimental-resty-imagefilter - https://github.com/mah0x211/experimental-resty-imagefilter

ちなみに、画像を保存してる箇所がボトルネックになってるので、次回はこの辺をどうにか出来ないか実験してみたいと思う。
