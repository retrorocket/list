#!/usr/bin/perl

use strict;
use warnings;
use utf8;

#use KCatch;
use Net::Twitter::Lite::WithAPIv1_1;
use Mojolicious::Lite;
#use Data::Dumper;
use List::Compare;
use JSON;

plugin 'mail';
my $consumer_key ="***";
my $consumer_secret = "***";
my $from_address = "***\@retrorocket.biz";

my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
	consumer_key => $consumer_key,
	consumer_secret => $consumer_secret,
	ssl => 1
);

# Display top page
get '/' => sub {
	my $self = shift;

	my $access_token = $self->session( 'access_token' ) || '';
	my $access_token_secret = $self->session( 'access_token_secret' ) || '';
	my $screen_name = $self->session( 'screen_name' ) || '';

	my $mode = $self->param('mode') || 'following';
	my $mail_mode = $self->param('mail') || 'false';

	#セッションにトークンが残っていない
	return $self->redirect_to( 'https://retrorocket.biz/list/auth.cgi?mode='.$mode."&mail=".$mail_mode ) unless ($access_token && $access_token_secret);
	$self->stash('name' => $screen_name);
	if($mail_mode ne 'false') {return $self->render('mail');}

} => 'index';

post '/list' => sub {

	my $self = shift;

	my $access_token = $self->session( 'access_token' ) || '';
	my $access_token_secret = $self->session( 'access_token_secret' ) || '';
	my $screen_name = $self->session( 'screen_name' ) || '';

	my $mode = $self->param('mode') || '';
	my $sender_address = $self->param('address') || 'false';
	my $mail_flag = $sender_address ne "false" ? 1 : 0;

	#トークンなし
	unless ($access_token && $access_token_secret) {
		if($mail_flag == 1){
			$self->mail(
				to      => $sender_address,
				subject => 'TimeLine Copier Result（fault）',
				data    => "TimeLine Copierの処理に失敗しました。：Twitterに認証されていません。" ,
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

	my $rand_num;
	my $filename;
	my $num;
	my $list;
	my $repeat = 0;
	my $only_count = -1;
	my @mem = ();

	if($mail_flag == 0){
		$rand_num = int(rand 10000);
		$filename = "/var/www/html/list/public/".$screen_name . $rand_num.".json";

		open(OUT, ">$filename");
		my %trig = ();
		$trig{complete} = 0;
		$trig{result} = "Processing";
		my $json_out = encode_json(\%trig);
		print OUT $json_out;
		close(OUT);
	}

	my $pid = fork;
	die "fork fault: $!" unless defined $pid;

	if($pid) {

		# 親プロセス
		if($mail_flag == 0){
			return $self->render(json =>{'result' => $screen_name . $rand_num, 'complete' => 0 });
		}
		return $self->render(json =>{'result' => $screen_name });

		#意味は無いが念のため。
		close (STDOUT);
		exit;
	}
	else {
		#子プロセス
		close (STDOUT);
		do {
			eval {
				if($repeat == 0) {
					$list = $nt->create_list({name=>'home_timeline_copy', mode=>'private', description =>"It\'s processing." });
					$num = $list->{id_str};
					sleep 2;
				
					my $hash;
					if($mode eq 'follower'){
						$hash = $nt->followers_ids({count=>4999});
					}
					else {
						$hash = $nt->friends_ids({count=>4999});
					}
					@mem = @{$hash->{ids}};

					$nt->add_list_member({list_id=>$num, screen_name=>$screen_name});
				}

				while ($only_count != 0) {
	
					my $magic = 50;
					my $count = @mem;

					my $hyaku = int($count / $magic);
					my $amari = $count % $magic;

					my $i = 0;
					for($i = 0; $i < $hyaku; $i++){
						eval {
							my @temp = @mem[$i*$magic ... (($i+1)*$magic)-1];
							my $str = join(',', @temp);
							$nt->add_list_members({list_id=>$num, user_id=>$str});
							sleep 1;
						};
					}
					if($amari > 0){
						eval {
							my @temp = @mem[$hyaku*$magic ... $hyaku*$magic+($amari-1)];
							my $str = join(',', @temp);
							#print $str;
							$nt->add_list_members({list_id=>$num, user_id=>$str});
							sleep 1;
						};
					}

				#リストに登録できた勢
					my $cursor = -1;
					my $list_members = $nt->list_members({list_id => $num, cursor => $cursor});

					my @list_mem;
					for my $a (@{$list_members->{users}}){
						push(@list_mem,$a->{id});
					}
					$cursor = $list_members->{next_cursor};
					while ($cursor != 0){
						$list_members = $nt->list_members({list_id => $num, cursor => $cursor});
						for my $a (@{$list_members->{users}}){
							push(@list_mem,$a->{id});
						}
						$cursor = $list_members->{next_cursor};
					}

					my $lc = List::Compare->new(\@mem, \@list_mem);
					my @only = $lc->get_Lonly;

					$only_count = @only;

					@mem = ();
					@mem = @only;
				}
			};
			if($@){
				$repeat++;
				if($mail_flag == 1 && $repeat == 1){
					$self->mail(
						to      => $sender_address,
						subject => 'TimeLine Copier Result (on process)',
						data    => "TimeLine Copierの処理が中断されました。15分後に処理を再開します。\n".$@ ,
						from    => $from_address
					);
					sleep 900;
				}
				elsif ($mail_flag == 1 && $repeat > 1) {
					$self->mail(
						to      => $sender_address,
						subject => 'TimeLine Copier Result (faulted)',
						data    => "TimeLine Copierの処理に失敗しました。\n".$@ ,
						from    => $from_address
					);
					$nt->update_list({list_id => $num, description => "error : ".$@});
					$self->session( expires => 1 );
					exit;
				}
				else {
					unlink($filename);
					$nt->update_list({list_id => $num, description => "error : ".$@});
					$self->session( expires => 1 );
					exit;
				}
			}
		} while($mail_flag == 1 && $repeat == 1);

		if($mail_flag == 1){

			$self->mail(
				to      => $sender_address,
				subject => 'TimeLine Copier Result (succeed)',
				data    => "TimeLine Copierの処理が完了しました。Twitterを確認して下さい。" ,
				from    => $from_address
			);
		}
		else {
			unlink($filename);
		}
		$nt->update_list({list_id => $num, description => "succeed"});
		$self->session( expires => 1 );
		#return $self->render(json =>{'result' => 'done'});
		exit;
	}

} => 'list';

# セッション消去
get '/logout' => sub {
	my $self = shift;
	$self->session( expires => 1 );
	#$self->render;
} => 'logout';

app->sessions->secure(1);
app->secret("***"); # セッション管理のために付けておく
app->start;


