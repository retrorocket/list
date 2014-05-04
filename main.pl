#!/usr/bin/perl

use strict;
use warnings;
use utf8;
#use bigint;

use Scalar::Util 'blessed';
use Net::Twitter::Lite::WithAPIv1_1;
use Mojolicious::Lite;
#use Data::Dumper;
use List::Compare;
use JSON;
use POSIX 'setsid';

plugin 'mail';

app->config(hypnotoad => {listen => ['http://*:secret']});
app->hook('before_dispatch' => sub {
		my $self = shift;
		if ($self->req->headers->header('X-Forwarded-Host')) {
			#Proxy Path setting
			my $path = shift @{$self->req->url->path->parts};
			push @{$self->req->url->base->path->parts}, $path;
		}
	});

my $consumer_key ="***";
my $consumer_secret = "***";
my $from_address = "xxx\@retrorocket.biz";

my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
	consumer_key => $consumer_key,
	consumer_secret => $consumer_secret,
	ssl => 1
);

sub getFaultedMember {
	my $list_id = shift;
	my $filename = shift;
	my $mem = shift;
	my $repeat_count = shift;

	my $cursor = -1;
	my $list_members = $nt->list_members({list_id => $list_id, cursor => $cursor});

	my @list_mem;
	for my $a (@{$list_members->{users}}){
		push(@list_mem,$a->{id_str});
	}
	$cursor = $list_members->{next_cursor};
	while ($cursor != 0){
		$list_members = $nt->list_members({list_id => $list_id, cursor => $cursor});
		for my $a (@{$list_members->{users}}){
			push(@list_mem,$a->{id_str});
		}
		$cursor = $list_members->{next_cursor};
	}

	my $lc = List::Compare->new($mem, \@list_mem);
	my @only = $lc->get_Lonly; #登録失敗者リスト

	my $add_faulted_count = @only;
	#JSON出力
	my $mem_count = @list_mem;
	open(OUT, ">$filename");
		my %trig = ();
		$trig{complete} = 0;
		$trig{repeat} = $repeat_count;
		$trig{result} = "Processing on ".$mem_count." members (left : ".$add_faulted_count." members)";
		my $json_out = encode_json(\%trig);
		print OUT $json_out;
	close(OUT);

	return @only;
}

# Display top page
get '/' => sub {
	my $self = shift;

	my $access_token = $self->session( 'access_token' ) || '';
	my $access_token_secret = $self->session( 'access_token_secret' ) || '';
	my $screen_name = $self->session( 'screen_name' ) || '';

	#セッションにトークンが残っていない
	return $self->redirect_to( 'http://retrorocket.biz/list' ) unless ($access_token && $access_token_secret);

	$self->stash('name' => $screen_name);

	my $mail_mode = $self->session('mail') || '';
	my $diff_mode = $self->session('diff') || '';

	if($mail_mode && $diff_mode) {return $self->render('diff_mail');}
	if($diff_mode) {return $self->render('diff');}
	if($mail_mode) {return $self->render('mail');}

} => 'index';


get '/auth' => sub {
	my $self = shift;
	my $mode = $self->param('mode') || '';
	my $mail = $self->param('mail') || '';
	my $diff = $self->param('diff') || '';

	$self->session( mode => $mode );
	$self->session( mail => $mail );
	$self->session( diff => $diff );

	my $cb_url = $self->url_for('auth_cb')->to_abs->scheme('https');
	my $url = $nt->get_authorization_url( callback => $cb_url );

	$self->session( token => $nt->request_token );
	$self->session( token_secret => $nt->request_token_secret );

	$self->redirect_to( $url );
} => 'auth';

get '/auth_cb' => sub {
	my $self = shift;

	my $verifier = $self->param('oauth_verifier') || '';
	my $token = $self->session('token') || '';
	my $token_secret = $self->session('token_secret') || '';

	$nt->request_token( $token );
	$nt->request_token_secret( $token_secret );

	# Access token取得
	my ($access_token, $access_token_secret, $user_id, $screen_name)
		= $nt->request_access_token( verifier => $verifier );

	# セッションに格納
	$self->session( access_token => $access_token );
	$self->session( access_token_secret => $access_token_secret );
	$self->session( screen_name => $screen_name );

	$self->redirect_to( $self->url_for('index')->to_abs->scheme('https') );
} => 'auth_cb';

get '/list_get' => sub {
	my $self = shift;
	my $access_token = $self->session( 'access_token' ) || '';
	my $access_token_secret = $self->session( 'access_token_secret' ) || '';
	my $screen_name = $self->session( 'screen_name' ) || '';
	return $self->render(json =>{'result' => "fault", 'complete' => -1}) unless ($access_token && $access_token_secret);

	$nt->access_token( $access_token );
	$nt->access_token_secret( $access_token_secret );

	eval{	
		my $lists = $nt->get_lists();
		my $lists_num = @$lists;
		if($lists_num == 0) { return $self->render(json =>{'result' => "fault", 'complete' => -1}); }

		my @get_list=();
		foreach my $elem (@$lists){
			my %trig = ();
			$trig{list_name} = $elem->{name};
			$trig{list_id} = $elem->{id_str};
			push(@get_list,\%trig);
		}
		return $self->render(json =>{'result' => "complete", 'complete' => \@get_list});
	};
	if($@){
		return $self->render(json =>{'result' => "fault", 'complete' => -1});
	}

} => 'list_get';

post '/list' => sub {

	my $self = shift;

	#Twitter API
	my $access_token = $self->session( 'access_token' ) || '';
	my $access_token_secret = $self->session( 'access_token_secret' ) || '';
	my $screen_name = $self->session( 'screen_name' ) || '';

	#各種モード切り替え
	my $mode = $self->session('mode') || '';
	my $sender_address = $self->param('address') || 'false';
	my $mail_flag = $sender_address ne "false" ? 1 : 0;

	#メール用メッセージ
	my $MAIL_FAULT_TITLE = "TimeLine Copier Result (faulted)";
	my $MAIL_FAULT_MESSAGE = "TimeLine Copierの処理に失敗しました。";

	my $MAIL_PROCESS_TITLE = "TimeLine Copier Result (on process)";
	my $MAIL_PROCESS_MESSAGE = "TimeLine Copierの処理が中断されました。15分後に処理を再開します。";

	my $MAIL_SUCCEED_TITLE = "TimeLine Copier Result (succeed)'";
	my $MAIL_SUCCEED_MESSAGE = "TimeLine Copierの処理が完了しました。Twitterを確認して下さい。";

	#トークンなし
	unless ($access_token && $access_token_secret) {
		if($mail_flag == 1){
			$self->mail(
				to      => $sender_address,
				subject => $MAIL_FAULT_TITLE,
				data    => $MAIL_FAULT_MESSAGE . "：Twitterに認証されていません。" ,
				from    => $from_address
			);
		}
		else {
			return $self->render(json =>{'result' => "fault", 'complete' => -1});
		}
		exit;
	}

	$nt->access_token( $access_token );
	$nt->access_token_secret( $access_token_secret );

	#JSON出力用パス＆処理開始前判定
	my $filename = app->home. "/public/".$screen_name.".json";
	if( -f $filename ) {
		return $self->render(json =>{'result' => "fault", 'complete' => -2});
		exit;
	}

	my $pid = fork();
	die "fork fault: $!" unless defined $pid;


	if($pid) {
		# 親プロセス
		$self->session( expires => 1 );
		return $self->render(json =>{'result' => $screen_name, 'complete' => 0 });
		#意味は無いが念のため。
		exit;
	}
	else {
		#子プロセス
		setsid;

		open (STDIN, "</dev/null");
		open (STDOUT, ">/dev/null");
		open (STDERR, ">&STDOUT");

		#処理開始JSON出力
		open(OUT, ">$filename");
			my %trig = ();
			$trig{complete} = 0;
			$trig{result} = "Processing ...";
			my $json_out = encode_json(\%trig);
			print OUT $json_out;
		close(OUT);

		#my $list;
		my $list_id; #リストID
		my @mem = (); #リスト登録対象

		eval{

			my $hash;
			if($mode eq 'follower'){
				$hash = $nt->followers_ids({count=>4999, stringify_ids =>'true'});
			}
			else {
				$hash = $nt->friends_ids({count=>4999, stringify_ids=>'true'});
			}
			@mem = @{$hash->{ids}};

			$list_id = $self->param('list_id') || '';
			if( $list_id ){
				my @only = &getFaultedMember($list_id, $filename, \@mem, 0);
				sleep 1;
				@mem = ();
				@mem = @only;
				$nt->update_list({list_id => $list_id, description => "It\'s processing." });
				sleep 2;
			}
			else{
				my $list = $nt->create_list({name=>'home_timeline_copy', mode=>'private', description =>"It\'s processing." });
				$list_id = $list->{id_str};
				sleep 2;
			}

			#自分を入れておく
			$nt->add_list_member({list_id=>$list_id, screen_name=>$screen_name});
		};
		if($@){
			if($mail_flag == 1){
				$self->mail(
					to      => $sender_address,
					subject => $MAIL_FAULT_TITLE,
					data    => $MAIL_FAULT_MESSAGE."\n".$@ ,
					from    => $from_address
				);
			}
			unlink($filename);
			close (SSTDIN);
			close (STDOUT);
			close (STDERR);
			exit;
		}

		my $error_count = 0; #APIエラー発生回数

		my $add_faulted_count = -1; #リスト登録に失敗した人数
		my $repeat_count = 0; #ループ回数
		my $REPEAT_MAGIC = 2; #この回数以上リピートしたらループを切る

		while ($add_faulted_count != 0 && $repeat_count < $REPEAT_MAGIC) {
			eval {
				my $temp_add_faulted_count = $add_faulted_count;

				my $magic = 50; #一度にリストにぶち込む人数
				my $count = @mem;

				my $hyaku = int($count / $magic);
				my $amari = $count % $magic;

				#割り切れる分の処理
				for(my $i = 0; $i < $hyaku; $i++){
					eval {
						my @temp = @mem[$i*$magic ... (($i+1)*$magic)-1];
						my $str = join(',', @temp);
						$nt->add_list_members({list_id=>$list_id, user_id=>$str});
						sleep 1;
					};
				}
				#端数
				if($amari > 0){
					eval {
						my @temp = @mem[$hyaku*$magic ... $hyaku*$magic+($amari-1)];
						my $str = join(',', @temp);
						#print $str;
						$nt->add_list_members({list_id=>$list_id, user_id=>$str});
						sleep 1;
					};
				}

				#リストに登録できた勢を計算する
				my @only = &getFaultedMember($list_id, $filename, \@mem, $repeat_count);
				$add_faulted_count = @only;
				if($add_faulted_count >= $temp_add_faulted_count) {$repeat_count++;}
				@mem = ();
				@mem = @only;
			};
			if( my $err = $@ ){
				die $@ unless blessed $err && $err->isa('Net::Twitter::Lite::Error');
				my $error = $err->code;
				$error_count++;

				#一回目のエラー、かつ404じゃないなら再開する
				if($mail_flag == 1 && $error_count == 1 && $error != 404){
					$self->mail(
						to      => $sender_address,
						subject => $MAIL_PROCESS_TITLE,
						data    => $MAIL_PROCESS_MESSAGE."\n".$@ ,
						from    => $from_address
					);
					sleep 900;
					next;
				}
				
				#失敗しました
				if($mail_flag == 1) {
					$self->mail(
						to      => $sender_address,
						subject => $MAIL_FAULT_TITLE,
						data    => $MAIL_FAULT_MESSAGE ."\n".$@ ,
						from    => $from_address
					);
				}
				$nt->update_list({list_id => $list_id, description => "error : ".$@});
				#$self->session( expires => 1 );
				unlink($filename);
				close (SSTDIN);
				close (STDOUT);
				close (STDERR);
				exit;
			}
		}

		#無限ループしそうになった
		if($repeat_count >= $REPEAT_MAGIC) {
			if($mail_flag == 1){
				$self->mail(
					to      => $sender_address,
					subject => $MAIL_FAULT_TITLE,
					data    => $add_faulted_count."名の存在しない・凍結された可能性のあるユーザをリストに登録できませんでした。Twitterを確認して下さい。" ,
					from    => $from_address
				);
			}
			$nt->update_list({list_id => $list_id, description => $add_faulted_count."名の存在しない・凍結された可能性のあるユーザをリストに登録できませんでした"});

			unlink($filename);
			close (SSTDIN);
			close (STDOUT);
			close (STDERR);
			exit;
		}

		if($mail_flag == 1){
			$self->mail(
				to      => $sender_address,
				subject => $MAIL_SUCCEED_TITLE,
				data    => $MAIL_SUCCEED_MESSAGE ,
				from    => $from_address
			);
		}
		$nt->update_list({list_id => $list_id, description => "succeed"});

		unlink($filename);
		close (SSTDIN);
		close (STDOUT);
		close (STDERR);
		exit;
	}

} => 'list';

# セッション消去
get '/logout' => sub {
	my $self = shift;
	$self->session( expires => 1 );
	#$self->render;
	return $self->render(json =>{'result' => "logout"});
} => 'logout';

app->sessions->secure(1);
app->secrets(["xxx"]); # セッション管理のために付けておく
app->start;
