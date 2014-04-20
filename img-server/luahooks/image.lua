local args = ngx.req.get_uri_args();
local size = tonumber( args.s );
local quality = tonumber( args.q );

if size or quality then
    local img = posix.realpath( ngx.var.document_root .. '/' .. ngx.var.uri );

    if img then
        ngx.log( ngx.ERR, img, ' size:', size, ' quality:', quality );
    end
end
