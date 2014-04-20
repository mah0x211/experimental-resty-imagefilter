var fs = require('fs'),
    highlight = require('highlight.js'),
    marked = require('marked');

marked.setOptions({
    gfm: true,
    highlight: function( code ){
        return highlight.highlightAuto(code).value;
    }
});

function outputPreview( filepath, output )
{
    fs.readFile( filepath, 'utf8', function( err, data )
    {
        if( err ){
            console.log( err );
        }
        else {
            fs.writeFileSync( output, [
                '<link rel="stylesheet" href="https://gist.githubusercontent.com/andyferra/2554919/raw/2e66cabdafe1c9a7f354aa2ebf5bc38265e638e5/github.css">',
                '<link rel="stylesheet" href="http://yandex.st/highlightjs/8.0/styles/github.min.css">',
                '<body>',
                marked( data ),
                '</body>'
            ].join('\n') );
            console.log( 'updated: ', (new Date()) );
        }
    });
}

function watchFile( err, filepath )
{
    if( err ){
        console.log( err );
    }
    else {
        var output = process.cwd() + '/preview.html';
        
        console.log( 'preview file: ', output );
        outputPreview( filepath, output );
        fs.watch( filepath ).on('change', function(){
            outputPreview( filepath, output );
        });
        console.log( 'start watching ', filepath );
    }
}

if( process.argv[2] ){
    fs.realpath( process.argv[2], watchFile );
}
else {
    console.log('filepath argument undefined');
}