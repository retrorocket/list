#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Net::Twitter::Lite::WithAPIv1_1;
use Mojolicious::Lite;
use Data::Dumper;
use Config::Pit;
use MongoDB;
use MongoDB::OID;

# Config::Pit
my $config = Config::Pit::get("list");

helper mango  => sub { state $mango = MongoDB::MongoClient->new };
helper pastes => sub { shift->mango->get_database($config->{data_base})->get_collection($config->{collection}) };

app->config(
    hypnotoad => {
        listen  => [ 'http://*:' . $config->{port} ],
        workers => 2,
    },
);
app->hook(
    'before_dispatch' => sub {
        my $self = shift;
        if ( $self->req->headers->header('X-Forwarded-Host') ) {

            #Proxy Path setting
            my $path = shift @{ $self->req->url->path->parts };
            push @{ $self->req->url->base->path->parts }, $path;
        }
    }
);

# Net::Twitter::Lite
my $consumer_key    = $config->{consumer_key};
my $consumer_secret = $config->{consumer_secret};

# index
get '/' => sub {
    my $self = shift;

    my $access_token        = $self->session('access_token')        || '';
    my $access_token_secret = $self->session('access_token_secret') || '';
    my $screen_name         = $self->session('screen_name')         || '';

    #セッションにトークンが残っていない
    return $self->redirect_to('https://retrorocket.biz/list')
        unless ( $access_token && $access_token_secret );

    $self->stash( 'name' => $screen_name );

    #my $mail_mode = $self->session('mail') || '';
    my $diff_mode = $self->session('diff') || '';

    #if($mail_mode && $diff_mode) {return $self->render('diff_mail');}
    if ($diff_mode) { return $self->render('diff'); }

    #if($mail_mode) {return $self->render('mail');}

} => 'index';

# checker
get '/check' => sub {
    my $self = shift;

    my $access_token        = $self->session('access_token')        || '';
    my $access_token_secret = $self->session('access_token_secret') || '';
    my $screen_name         = $self->session('screen_name')         || '';

    #セッションにトークンが残っていない
    return $self->redirect_to('https://retrorocket.biz/list')
        unless ( $access_token && $access_token_secret );

#$self->app->log->error(Dumper $self->pastes->find({"screen_name" => $screen_name}));
    my $doc = $self->pastes->find_one( { screen_name => $screen_name } );
    my $doc_name = $doc->{screen_name} || "";

    # 始めて実行する→処理に進む
    unless ($doc_name) {
        $self->session( check_code => 1 );  #チェックポイントフラグ
        $self->redirect_to(
            $self->url_for('index')->to_abs->scheme('https') );
    }

    my $check_code = $doc->{complete};      #判定用コード
    if ($check_code) {
        $self->session( check_code => $check_code );
    }                                       #チェックポイントフラグ

    # BAN
    if ( $self->session('user_id') == $config->{ban} ) {
        $self->session( expires => 1 );
        return $self->render(
            check_code => -2,
            message =>
                "このアカウントは、管理者から迷惑行為を行っていると認識され、かつ、警告を無視した上でリスト作成を行ったため、ツールの使用が禁止されました。解除が必要な場合は管理者まで連絡してください。"
        );
    }

    # 前回無事に終了している
    if ( $check_code == 429 ) {

        # エラー発生
        return $self->render(
            check_code => 429,
            message =>
                "前回API切れを起こしています。前回リストを作成してから15分以上経過していない場合、作成ページへ進んでもリストの作成に失敗することがあります。"
        );
    }
    elsif ( $check_code == 404 ) {

        # 謎エラー
        return $self->render(
            check_code => 404,
            message =>
                "前回原因が不明な404エラーが発生しています。作成ページへ進んでもリストの作成に失敗することがあります。"
        );
    }
    elsif ( $check_code == 1 ) {

        # 作成中
        return $self->render(
            check_code => 1,
            message =>
                "このアカウントで現在リストを作成中です。作成ページヘ進むと現在の状況を確認することができます。"
        );
    }
    else {
        $self->redirect_to(
            $self->url_for('index')->to_abs->scheme('https') );
    }

} => 'check';

# 進捗確認
get '/progress' => sub {
    my $self = shift;

    my $screen_name = $self->param('screen_name') || "";
    return $self->render(
        json => {
            'result'   => "You did not create the list in this account.",
            'complete' => -1
        }
    ) unless ($screen_name);

    my $doc = $self->pastes->find_one( { screen_name => $screen_name } );
    my $doc_name = $doc->{screen_name} || "";

    # 名前がない
    unless ($doc_name) {
        return $self->render(
            json => {
                'result'   => "You did not create the list in this account.",
                'complete' => -1
            }
        );
    }

    # 状況に応じてjsonを返却する
    return $self->render( json =>
            { 'complete' => $doc->{complete}, 'result' => $doc->{result} } );
} => 'progress';

get '/auth' => sub {
    my $self = shift;

    #my $doc = $self->pastes->find_one({screen_name => "retrorocket"});
    my $mode = $self->param('mode') || '';
    my $mail = $self->param('mail') || '';
    my $diff = $self->param('diff') || '';

    $self->session( mode => $mode );
    $self->session( mail => $mail );
    $self->session( diff => $diff );

    my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
        consumer_key    => $consumer_key,
        consumer_secret => $consumer_secret,
        ssl             => 1
    );
    my $cb_url = $self->url_for('auth_cb')->to_abs->scheme('https');
    my $url    = $nt->get_authorization_url( callback => $cb_url );

    $self->session( token        => $nt->request_token );
    $self->session( token_secret => $nt->request_token_secret );

    $self->redirect_to($url);
} => 'auth';

get '/auth_cb' => sub {
    my $self = shift;

    my $verifier     = $self->param('oauth_verifier') || '';
    my $token        = $self->session('token')        || '';
    my $token_secret = $self->session('token_secret') || '';

    my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
        consumer_key    => $consumer_key,
        consumer_secret => $consumer_secret,
        ssl             => 1
    );
    $nt->request_token($token);
    $nt->request_token_secret($token_secret);

    # Access token取得
    my ( $access_token, $access_token_secret, $user_id, $screen_name )
        = $nt->request_access_token( verifier => $verifier );

    # Sessionに格納
    $self->session( access_token        => $access_token );
    $self->session( access_token_secret => $access_token_secret );
    $self->session( screen_name         => $screen_name );
    $self->session( user_id             => $user_id );

    $self->redirect_to( $self->url_for('check')->to_abs->scheme('https') );
} => 'auth_cb';

get '/list_get' => sub {
    my $self                = shift;
    my $access_token        = $self->session('access_token') || '';
    my $access_token_secret = $self->session('access_token_secret') || '';
    my $screen_name         = $self->session('screen_name') || '';
    return $self->render( json => { 'result' => "fault", 'complete' => -1 } )
        unless ( $access_token && $access_token_secret );

    my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
        consumer_key    => $consumer_key,
        consumer_secret => $consumer_secret,
        ssl             => 1
    );
    $nt->access_token($access_token);
    $nt->access_token_secret($access_token_secret);

    eval {
        my $lists     = $nt->get_lists();
        my $lists_num = @$lists;
        if ( $lists_num == 0 ) {
            return $self->render(
                json => { 'result' => "fault", 'complete' => -1 } );
        }

        my @get_list = ();
        foreach my $elem (@$lists) {
            my %trig = ();
            $trig{list_name} = $elem->{name};
            $trig{list_id}   = $elem->{id_str};
            push( @get_list, \%trig );
        }
        return $self->render(
            json => { 'result' => "complete", 'complete' => \@get_list } );
    };
    if ($@) {
        return $self->render(
            json => { 'result' => "fault", 'complete' => -1 } );
    }

} => 'list_get';

post '/list' => sub {

    my $self = shift;

    #Twitter API
    my $access_token        = $self->session('access_token')        || '';
    my $access_token_secret = $self->session('access_token_secret') || '';
    my $screen_name         = $self->session('screen_name')         || '';

    #check_code
    my $check_code = $self->session('check_code') || '';

    #各種モード判定
    my $mode           = $self->session('mode')  || "following";
    my $sender_address = $self->session('mail')  || 0;
    my $list_id        = $self->param('list_id') || 0;

    #トークンなし＆チェックポイント未通過
    unless ( $access_token && $access_token_secret && $check_code ) {
        return $self->render( json =>
                { 'result' => "You are Not authorized.", 'complete' => -1 } );
    }

    my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
        consumer_key    => $consumer_key,
        consumer_secret => $consumer_secret,
        ssl             => 1
    );
    $nt->access_token($access_token);
    $nt->access_token_secret($access_token_secret);

    my $doc = $self->pastes->find_one( { screen_name => $screen_name } );
    my $doc_name = $doc->{screen_name} || "";

    #my $check_code = $doc->{complete};

    # 実行中
    if ( $doc_name && $doc->{complete} == 1 ) {
        $self->session( expires => 1 );
        return $self->render(
            json => { 'result' => $screen_name, 'complete' => 0 } );
    }

    #該当ID削除（なまえない人を指定したらどうなる？）
    $self->pastes->delete_one( { screen_name => $screen_name } );

    #ID作成
    my $tokens = {

        #check_code => 1,
        screen_name => $screen_name,
    };
    $self->pastes->insert_one($tokens);

    #JSON出力用パス＆処理開始前判定
    #my $filename = app->home. "/public/".$screen_name.".json";
    #if( -f $filename ) {
    #    return $self->render(json =>{'result' => "fault", 'complete' => -2});
    #}

#$access_token, $access_token_secret, $screen_name, $mode, $list_id, $sender_address
    system(   app->home
            . "/list_script.pl "
            . $access_token . " "
            . $access_token_secret . " "
            . $screen_name . " "
            . $mode . " "
            . $list_id . " "
            . $sender_address . " >> "
            . app->home
            . "/log/list.log 2>&1 &" );
    $self->session( expires => 1 );
    return $self->render(
        json => { 'result' => $screen_name, 'complete' => 0 } );

} => 'list';

# セッション消去
get '/logout' => sub {
    my $self = shift;
    $self->session( expires => 1 );
    return $self->render( json => { 'result' => "logout" } );
} => 'logout';

app->sessions->secure(1);
app->sessions->cookie_name( $config->{session_name} );
app->secrets( [$config->{session_secrets}] );    # セッション管理のために付けておく
app->start;
