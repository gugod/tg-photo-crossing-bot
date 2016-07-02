#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;

use Data::Printer;

use List::Util qw(max);
use List::UtilsBy qw(max_by);
use Getopt::Long qw(GetOptions);
use Mojo::JSON qw(encode_json decode_json);
use Mojo::IOLoop;
use Mojo::Util;

use WWW::Telegram::BotAPI;
my $CONTEXT = {};

sub tg_get_updates {
    return unless $CONTEXT->{tg_bot};
    state $max_update_id = 0;

    my $tgbot = $CONTEXT->{tg_bot};
    $tgbot->api_request(
        'getUpdates',
        { $max_update_id ? (offset => 1+$max_update_id) : () },
        sub {
            my ($ua, $tx) = @_;
            if ($tx->success) {
                my $res = $tx->res->json;
                for my $m (@{$res->{result}}) {
                    $max_update_id = max($max_update_id, $m->{update_id});
                    if (exists $m->{message}{photo}) {
                        say "Photo:" . encode_json($m->{message}{photo});
                        my $photo = max_by { $_->{width} } @{ $m->{message}{photo} };
                        push @{$CONTEXT->{files}}, $photo->{file_id};
                    } else {
                        say "No photo: " . encode_json($m);
                    }
                }
            } else {
                say "getUpdates failed: " . Mojo::Util::dumper( $tx->error );
            }
        }
    );
}

sub tg_init {
    my ($token) = @_;
    my $tgbot = WWW::Telegram::BotAPI->new( token => $token, async => 1 );

    my $get_me_cb;
    $get_me_cb = sub  {
        my ($ua, $tx) = @_;
        if ($tx->success) {
            my $r = $tx->res->json;
            Mojo::Util::dumper(['getMe', $r]);
            Mojo::IOLoop->recurring( 15, \&tg_get_updates );
        } else {
            Mojo::Util::dumper(['getMe Failed.', $tx->res->body]);
            Mojo::IOLoop->timer( 5 => sub { $tgbot->api_request(getMe => $get_me_cb) });
        } 
    };

    $CONTEXT->{files} = [];
    my $download_file_cb = sub {
        return unless @{$CONTEXT->{files}};
        my $file_id = pop(@{$CONTEXT->{files}});

        $tgbot->api_request(
            'getFile',
            { file_id => $file_id },
            sub {
                my ($ua, $tx) = @_;
                my $r = $tx->res->json;
                if ($r->{ok}) {
                    my $file_path = $r->{result}{file_path};
                    my $file_url = "https://api.telegram.org/file/bot${token}/${file_path}";
                    say "file url: ${file_url}";
                }
            }
          );
    };
    
    Mojo::IOLoop->timer( 5 => sub { $tgbot->api_request(getMe => $get_me_cb) });
    Mojo::IOLoop->recurring( 15 => $download_file_cb );

    return $tgbot;
}



sub MAIN {
    my (%args) = @_;
    $CONTEXT->{tg_bot}  = tg_init( $args{telegram_token} );
    Mojo::IOLoop->start;
}

my %args;
GetOptions(
    \%args,
    "telegram_token=s",
);
MAIN(%args);
